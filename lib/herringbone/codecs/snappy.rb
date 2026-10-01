# frozen_string_literal: true

module Herringbone
  # Pure-Ruby compression codecs for Parquet pages: Snappy, and LZ4 (raw blocks and the Hadoop framing).
  # Compression dispatches to these; GZIP uses Zlib and ZSTD/BROTLI use external gems.
  module Codecs
    # Pure-Ruby implementation of the raw Snappy block format (as used by Parquet),
    # see https://github.com/google/snappy/blob/main/format_description.txt
    #
    # When the `snappy` gem (a binding to Google's libsnappy) is loaded, it is used instead:
    # 12x faster decompression and 27x faster compression. It is optional and only a speedup: if
    # it is missing, the pure-Ruby code below is used silently. Both produce raw Snappy blocks the
    # other reads.
    #
    # 32-bit loads are done with four getbyte calls rather than unpack1(offset:) to stay
    # compatible with Ruby 3.0 - the speed difference on MRI is marginal.
    module Snappy
      # Raised for corrupt or truncated Snappy input, and for input too large to compress.
      class Error < StandardError; end

      # The compressor works on independent 64 KiB fragments, as the reference implementation does.
      BLOCK_SIZE = 1 << 16
      # Size of the match-finder hash table, in bits (16384 entries).
      HASH_BITS = 14
      # Right shift that keeps the top HASH_BITS bits of the 32-bit multiplicative hash.
      HASH_SHIFT = 32 - HASH_BITS
      # Multiplier of the reference implementation's 4-byte hash.
      HASH_MUL = 0x1e35a7bd
      INPUT_MARGIN = 15 # bytes at the block end never searched for matches, as in the reference
      # The length preamble is a 32-bit varint, so no block may decompress to more than this.
      MAX_UNCOMPRESSED = (1 << 32) - 1

      # Name of the optional native gem.
      NATIVE_GEM = "snappy"

      module_function

      # @param input [String] raw snappy block
      # @return [String] decompressed bytes in ASCII-8BIT
      # @raise [Error] if the block is corrupt or truncated
      def decompress(input)
        src = (input.encoding == Encoding::BINARY) ? input : input.b
        if (lib = native)
          begin
            return lib.inflate(src)
          rescue lib::Error => e
            raise Error, "corrupt snappy data (#{e.message})"
          end
        end
        return decompress_io_buffer(src) if IOBufferSupport::AVAILABLE
        decompress_string(src)
      end

      # The backend in use: :native (the snappy gem) or :ruby
      # @return [Symbol] +:native+ or +:ruby+
      def backend
        native ? :native : :ruby
      end

      # For tests and benchmarks: :ruby forces pure Ruby, :native the snappy gem
      # (UnsupportedError if it is not loaded), nil goes back to the default
      # @param name [Symbol, nil] +:ruby+, +:native+ or nil
      # @return [void]
      # @raise [UnsupportedError] if +:native+ is requested and the gem is not loaded
      # @raise [ArgumentError] for any other backend name
      def backend=(name)
        @native = case name
        when :ruby then false
        when :native
          native_library || raise(UnsupportedError, "The \"#{NATIVE_GEM}\" gem is not loaded (require \"#{NATIVE_GEM}\")")
        when nil then nil
        else raise ArgumentError, "Unknown Snappy backend #{name.inspect} (expected :ruby, :native or nil)"
        end
      end

      # The native library to use: the snappy gem when it is loaded, unless backend= forced one.
      # @return [Module, nil] the +::Snappy+ module, or nil when the pure-Ruby code should run
      def native
        native = @native
        native = native_library if native.nil?
        native || nil
      end

      # Not memoized, so that it works the same in every Ractor and once the gem is required later.
      # @return [Module, false] the +::Snappy+ module, or false if it is not loaded or lacks inflate/deflate
      def native_library
        (defined?(::Snappy.inflate) && defined?(::Snappy.deflate)) ? ::Snappy : false
      end

      # Decompresses into a preallocated IO::Buffer: copies do not allocate intermediate Strings.
      # @param src [String] raw snappy block in ASCII-8BIT
      # @return [String] decompressed bytes in ASCII-8BIT
      # @raise [Error] if the block is corrupt or truncated
      def decompress_io_buffer(src)
        n = src.bytesize
        expected, pos = read_varint(src, n)
        return "".b if expected.zero? && pos == n
        out = IO::Buffer.new([expected, 1].max)
        inbuf = IO::Buffer.for(src)
        op = 0
        while pos < n
          tag = src.getbyte(pos)
          pos += 1
          kind = tag & 3
          if kind == 0
            len = tag >> 2
            if len >= 60
              nbytes = len - 59
              raise Error, "truncated literal length" if pos + nbytes > n
              len = 0
              nbytes.times { |i| len |= src.getbyte(pos + i) << (8 * i) }
              pos += nbytes
            end
            len += 1
            raise Error, "literal overruns input" if pos + len > n
            raise Error, "output exceeds declared length" if op + len > expected
            out.copy(inbuf, op, len, pos)
            op += len
            pos += len
            next
          elsif kind == 1
            raise Error, "truncated copy" if pos >= n
            len = ((tag >> 2) & 7) + 4
            offset = ((tag >> 5) << 8) | src.getbyte(pos)
            pos += 1
          elsif kind == 2
            raise Error, "truncated copy" if pos + 2 > n
            len = (tag >> 2) + 1
            offset = src.getbyte(pos) | (src.getbyte(pos + 1) << 8)
            pos += 2
          else
            raise Error, "truncated copy" if pos + 4 > n
            len = (tag >> 2) + 1
            offset = src.getbyte(pos) | (src.getbyte(pos + 1) << 8) |
              (src.getbyte(pos + 2) << 16) | (src.getbyte(pos + 3) << 24)
            pos += 4
          end
          raise Error, "invalid copy offset #{offset}" if offset == 0 || offset > op
          raise Error, "output exceeds declared length" if op + len > expected
          if offset >= len
            out.copy(out, op, len, op - offset)
          else
            # Overlapping copy of a pattern with period `offset`: each copy doubles the
            # replicated region, and never overlaps its own source.
            from = op - offset
            done = 0
            step = offset
            while done < len
              chunk = len - done
              chunk = step if chunk > step
              out.copy(out, op + done, chunk, from)
              done += chunk
              step <<= 1
            end
          end
          op += len
        end
        raise Error, "decompressed #{op} bytes, expected #{expected}" if op != expected
        out.get_string(0, expected)
      ensure
        inbuf&.free
      end

      # Decompresses by appending to a String; the fallback when IO::Buffer is not available.
      # @param src [String] raw snappy block in ASCII-8BIT
      # @return [String] decompressed bytes in ASCII-8BIT
      # @raise [Error] if the block is corrupt or truncated
      def decompress_string(src)
        n = src.bytesize
        expected, pos = read_varint(src, n)
        out = String.new(capacity: expected, encoding: Encoding::BINARY)

        while pos < n
          tag = src.getbyte(pos)
          pos += 1

          case tag & 3
          when 0 # literal
            len = tag >> 2
            if len >= 60
              nbytes = len - 59
              raise Error, "truncated literal length" if pos + nbytes > n
              len = 0
              nbytes.times { |i| len |= src.getbyte(pos + i) << (8 * i) }
              pos += nbytes
            end
            len += 1
            raise Error, "literal overruns input" if pos + len > n
            raise Error, "output exceeds declared length" if out.bytesize + len > expected
            out << src.byteslice(pos, len)
            pos += len
            next
          when 1 # copy, 1-byte offset
            raise Error, "truncated copy" if pos >= n
            len = ((tag >> 2) & 7) + 4
            offset = ((tag >> 5) << 8) | src.getbyte(pos)
            pos += 1
          when 2 # copy, 2-byte offset
            raise Error, "truncated copy" if pos + 2 > n
            len = (tag >> 2) + 1
            offset = src.getbyte(pos) | (src.getbyte(pos + 1) << 8)
            pos += 2
          else # copy, 4-byte offset
            raise Error, "truncated copy" if pos + 4 > n
            len = (tag >> 2) + 1
            offset = src.getbyte(pos) | (src.getbyte(pos + 1) << 8) |
              (src.getbyte(pos + 2) << 16) | (src.getbyte(pos + 3) << 24)
            pos += 4
          end

          produced = out.bytesize
          raise Error, "invalid copy offset #{offset}" if offset == 0 || offset > produced
          raise Error, "output exceeds declared length" if produced + len > expected

          if offset >= len
            out << out.byteslice(produced - offset, len)
          else
            # Overlapping copy: the source is a pattern with period `offset`. Double it
            # until it covers `len` (keeps whole periods, so it stays in phase).
            pattern = out.byteslice(produced - offset, offset)
            pattern << pattern while pattern.bytesize < len
            out << pattern.byteslice(0, len)
          end
        end

        raise Error, "decompressed #{out.bytesize} bytes, expected #{expected}" if out.bytesize != expected
        out
      end

      # @param input [String] bytes to compress
      # @return [String] raw snappy block in ASCII-8BIT
      # @raise [Error] if the input is larger than MAX_UNCOMPRESSED
      def compress(input)
        src = (input.encoding == Encoding::BINARY) ? input : input.b
        n = src.bytesize
        # Checked for libsnappy too: it would truncate the 32-bit length preamble without complaint
        raise Error, "input too large for snappy" if n > MAX_UNCOMPRESSED
        if (lib = native)
          return lib.deflate(src)
        end

        out = String.new(capacity: 32 + n + n / 6, encoding: Encoding::BINARY)
        write_varint(out, n)
        table = Array.new(1 << HASH_BITS, 0)
        start = 0
        while start < n
          len = n - start
          len = BLOCK_SIZE if len > BLOCK_SIZE
          table.fill(0)
          compress_block(src, start, len, out, table)
          start += len
        end
        out
      end

      # Reads the uncompressed-length preamble (a little-endian base-128 varint) at the start of +src+.
      # @param src [String] raw snappy block
      # @param n [Integer] byte size of +src+
      # @return [Array(Integer, Integer)] the declared uncompressed length and the offset just past the varint
      # @raise [Error] if the varint is truncated, longer than 5 bytes or exceeds MAX_UNCOMPRESSED
      def read_varint(src, n)
        value = 0
        shift = 0
        pos = 0
        while true
          raise Error, "truncated length preamble" if pos >= n
          byte = src.getbyte(pos)
          pos += 1
          value |= (byte & 0x7f) << shift
          break if byte < 0x80
          shift += 7
          raise Error, "length preamble too long" if shift > 28
        end
        raise Error, "declared length too large" if value > MAX_UNCOMPRESSED
        [value, pos]
      end

      # Appends +value+ as a little-endian base-128 varint (the length preamble).
      # @param out [String] binary output buffer, appended to
      # @param value [Integer] non-negative length to encode
      # @return [String] +out+
      def write_varint(out, value)
        while value >= 0x80
          out << ((value & 0x7f) | 0x80)
          value >>= 7
        end
        out << value
      end

      # Mirrors CompressFragment from the reference implementation. Table entries are
      # positions relative to `base`; matches never cross the block boundary.
      # The 4-byte little-endian word at every position of the block is unpacked up front
      # (in C, via String#unpack) so hashing and match checks are single Array lookups.
      # @param src [String] whole input in ASCII-8BIT
      # @param base [Integer] offset of the fragment in +src+
      # @param len [Integer] fragment length, at most BLOCK_SIZE
      # @param out [String] binary output buffer, appended to
      # @param table [Array<Integer>] zeroed hash table of 1 << HASH_BITS fragment-relative positions
      # @return [void]
      def compress_block(src, base, len, out, table)
        ip_end = base + len
        next_emit = base

        if len >= INPUT_MARGIN
          words = block_words(src, base, len)
          ip_limit = ip_end - INPUT_MARGIN
          ip = base + 1
          next_hash = ((words[1][0] * HASH_MUL) & 0xffffffff) >> HASH_SHIFT
          done = false

          until done
            # Scan for a 4-byte match, skipping faster the longer we find nothing.
            skip = 32
            next_ip = ip
            candidate = nil
            while true
              ip = next_ip
              h = next_hash
              next_ip = ip + (skip >> 5)
              skip += 1
              if next_ip > ip_limit
                done = true
                break
              end
              rel_next = next_ip - base
              next_hash = ((words[rel_next & 3][rel_next >> 2] * HASH_MUL) & 0xffffffff) >> HASH_SHIFT
              rel = table[h]
              candidate = base + rel
              table[h] = ip - base
              rel_ip = ip - base
              break if words[rel_ip & 3][rel_ip >> 2] == words[rel & 3][rel >> 2]
            end
            break if done

            emit_literal(out, src, next_emit, ip - next_emit)

            # Emit copies for as long as the position right after a copy matches again.
            while true
              matched = 4 + match_length_words(words, src, base, candidate + 4, ip + 4, ip_end)
              emit_copy(out, ip - candidate, matched)
              ip += matched
              next_emit = ip
              if ip >= ip_limit
                done = true
                break
              end
              rel_ip = ip - base
              prev = rel_ip - 1
              table[((words[prev & 3][prev >> 2] * HASH_MUL) & 0xffffffff) >> HASH_SHIFT] = prev
              cur = words[rel_ip & 3][rel_ip >> 2]
              h = ((cur * HASH_MUL) & 0xffffffff) >> HASH_SHIFT
              rel = table[h]
              candidate = base + rel
              table[h] = rel_ip
              break unless cur == words[rel & 3][rel >> 2]
            end
            break if done

            ip += 1
            rel_ip = ip - base
            next_hash = ((words[rel_ip & 3][rel_ip >> 2] * HASH_MUL) & 0xffffffff) >> HASH_SHIFT
          end
        end

        emit_literal(out, src, next_emit, ip_end - next_emit) if next_emit < ip_end
      end

      # words[k][j] is the 4-byte little-endian value at base + 4 * j + k, so the word at
      # relative position i is words[i & 3][i >> 2]
      # @param src [String] whole input in ASCII-8BIT
      # @param base [Integer] offset of the fragment in +src+
      # @param len [Integer] fragment length
      # @return [Array<Array<Integer>>] four arrays of 32-bit words, one per byte phase
      def block_words(src, base, len)
        Array.new(4) { |k| src.byteslice(base + k, len - k).unpack("V*") }
      end

      # Like match_length, but compares 4 bytes at a time using the unpacked block words,
      # which avoids allocating substrings for the (common) short matches.
      # Falls back to match_length once a match reaches 64 bytes.
      # @param words [Array<Array<Integer>>] fragment words from block_words
      # @param src [String] whole input in ASCII-8BIT
      # @param base [Integer] offset of the fragment in +src+
      # @param s1 [Integer] absolute offset of the earlier occurrence
      # @param s2 [Integer] absolute offset of the current position (s1 < s2)
      # @param limit [Integer] absolute offset not to read past (the fragment end)
      # @return [Integer] number of equal bytes starting at s1 and s2
      def match_length_words(words, src, base, s1, s2, limit)
        start = s2
        r1 = s1 - base
        r2 = s2 - base
        last_word = limit - base - 4
        while r2 <= last_word && words[r1 & 3][r1 >> 2] == words[r2 & 3][r2 >> 2]
          r1 += 4
          r2 += 4
          return (base + r2 - start) + match_length(src, base + r1, base + r2, limit) if r2 - (start - base) >= 64
        end
        s1 = base + r1
        s2 = base + r2
        while s2 < limit && src.getbyte(s1) == src.getbyte(s2)
          s1 += 1
          s2 += 1
        end
        s2 - start
      end

      # Number of equal bytes at s1 and s2 (s1 < s2), not reading past limit. Gallops
      # with byteslice comparisons (memcmp) to avoid per-byte loops on long matches.
      # @param src [String] whole input in ASCII-8BIT
      # @param s1 [Integer] absolute offset of the earlier occurrence
      # @param s2 [Integer] absolute offset of the current position
      # @param limit [Integer] absolute offset not to read past
      # @return [Integer] number of equal bytes
      def match_length(src, s1, s2, limit)
        start = s2
        return 0 if s2 >= limit || src.getbyte(s1) != src.getbyte(s2)

        step = 8
        growing = true
        while step > 0
          if s2 + step <= limit && src.byteslice(s1, step) == src.byteslice(s2, step)
            s1 += step
            s2 += step
            if growing
              step <<= 1 if step < 4096
            else
              step >>= 1
            end
          else
            growing = false
            step >>= 1
          end
        end
        s2 - start
      end

      # Appends a literal element: the tag (with a 1-4 byte length extension for long literals)
      # followed by the bytes themselves. Does nothing for an empty literal.
      # @param out [String] binary output buffer, appended to
      # @param src [String] whole input in ASCII-8BIT
      # @param pos [Integer] offset of the literal bytes in +src+
      # @param len [Integer] number of literal bytes
      # @return [String, nil] +out+, or nil when +len+ is zero
      def emit_literal(out, src, pos, len)
        return if len == 0
        n = len - 1
        if n < 60
          out << (n << 2)
        elsif n < 0x100
          out << (60 << 2) << n
        elsif n < 0x10000
          out << (61 << 2) << (n & 0xff) << (n >> 8)
        elsif n < 0x1000000
          out << (62 << 2) << (n & 0xff) << ((n >> 8) & 0xff) << (n >> 16)
        else
          out << (63 << 2) << (n & 0xff) << ((n >> 8) & 0xff) << ((n >> 16) & 0xff) << (n >> 24)
        end
        out << src.byteslice(pos, len)
      end

      # Offsets are always < 64KB (matches stay within a block), so 4-byte offsets are never needed.
      # Long matches are split into copies of at most 64 bytes, never leaving a remainder under 4.
      # @param out [String] binary output buffer, appended to
      # @param offset [Integer] backward distance to the match source, 1...65536
      # @param len [Integer] match length, at least 4
      # @return [String] +out+
      def emit_copy(out, offset, len)
        while len >= 68
          emit_copy_upto64(out, offset, 64)
          len -= 64
        end
        if len > 64
          emit_copy_upto64(out, offset, 60)
          len -= 60
        end
        emit_copy_upto64(out, offset, len)
      end

      # Appends one copy element: the 2-byte form (1-byte offset) when len is 4..11 and offset < 2048,
      # otherwise the 3-byte form with a 2-byte offset.
      # @param out [String] binary output buffer, appended to
      # @param offset [Integer] backward distance to the match source, 1...65536
      # @param len [Integer] copy length, 4..64
      # @return [String] +out+
      def emit_copy_upto64(out, offset, len)
        if len < 12 && offset < 2048
          out << (1 | ((len - 4) << 2) | ((offset >> 8) << 5)) << (offset & 0xff)
        else
          out << (2 | ((len - 1) << 2)) << (offset & 0xff) << (offset >> 8)
        end
      end

      private_class_method :native, :native_library, :decompress_io_buffer, :decompress_string, :read_varint, :write_varint, :compress_block, :block_words, :match_length_words,
        :match_length, :emit_literal, :emit_copy, :emit_copy_upto64
    end
  end
end

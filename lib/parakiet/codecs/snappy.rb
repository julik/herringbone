# frozen_string_literal: true

module Parakiet
  module Codecs
    # Pure-Ruby implementation of the raw Snappy block format (as used by Parquet),
    # see https://github.com/google/snappy/blob/main/format_description.txt
    #
    # 32-bit loads are done with four getbyte calls rather than unpack1(offset:) to stay
    # compatible with Ruby 3.0 - the speed difference on MRI is marginal.
    module Snappy
      class Error < StandardError; end

      BLOCK_SIZE = 1 << 16
      HASH_BITS = 14
      HASH_SHIFT = 32 - HASH_BITS
      HASH_MUL = 0x1e35a7bd
      INPUT_MARGIN = 15 # bytes at the block end never searched for matches, as in the reference
      MAX_UNCOMPRESSED = (1 << 32) - 1

      module_function

      # @param input [String] raw snappy block
      # @return [String] decompressed bytes in ASCII-8BIT
      def decompress(input)
        src = input.encoding == Encoding::BINARY ? input : input.b
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
      def compress(input)
        src = input.encoding == Encoding::BINARY ? input : input.b
        n = src.bytesize
        raise Error, "input too large for snappy" if n > MAX_UNCOMPRESSED

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

      def read_varint(src, n)
        value = 0
        shift = 0
        pos = 0
        loop do
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

      def write_varint(out, value)
        while value >= 0x80
          out << ((value & 0x7f) | 0x80)
          value >>= 7
        end
        out << value
      end

      # Mirrors CompressFragment from the reference implementation. Table entries are
      # positions relative to `base`; matches never cross the block boundary.
      def compress_block(src, base, len, out, table)
        ip_end = base + len
        next_emit = base

        if len >= INPUT_MARGIN
          ip_limit = ip_end - INPUT_MARGIN
          ip = base + 1
          next_hash = hash32(src, ip)
          done = false

          until done
            # Scan for a 4-byte match, skipping faster the longer we find nothing.
            skip = 32
            next_ip = ip
            candidate = nil
            loop do
              ip = next_ip
              h = next_hash
              next_ip = ip + (skip >> 5)
              skip += 1
              if next_ip > ip_limit
                done = true
                break
              end
              next_hash = hash32(src, next_ip)
              candidate = base + table[h]
              table[h] = ip - base
              break if src.getbyte(ip) == src.getbyte(candidate) &&
                src.getbyte(ip + 1) == src.getbyte(candidate + 1) &&
                src.getbyte(ip + 2) == src.getbyte(candidate + 2) &&
                src.getbyte(ip + 3) == src.getbyte(candidate + 3)
            end
            break if done

            emit_literal(out, src, next_emit, ip - next_emit)

            # Emit copies for as long as the position right after a copy matches again.
            loop do
              matched = 4 + match_length(src, candidate + 4, ip + 4, ip_end)
              emit_copy(out, ip - candidate, matched)
              ip += matched
              next_emit = ip
              if ip >= ip_limit
                done = true
                break
              end
              table[hash32(src, ip - 1)] = ip - 1 - base
              h = hash32(src, ip)
              candidate = base + table[h]
              table[h] = ip - base
              break unless src.getbyte(ip) == src.getbyte(candidate) &&
                src.getbyte(ip + 1) == src.getbyte(candidate + 1) &&
                src.getbyte(ip + 2) == src.getbyte(candidate + 2) &&
                src.getbyte(ip + 3) == src.getbyte(candidate + 3)
            end
            break if done

            ip += 1
            next_hash = hash32(src, ip)
          end
        end

        emit_literal(out, src, next_emit, ip_end - next_emit) if next_emit < ip_end
      end

      def hash32(src, i)
        v = src.getbyte(i) | (src.getbyte(i + 1) << 8) | (src.getbyte(i + 2) << 16) | (src.getbyte(i + 3) << 24)
        ((v * HASH_MUL) & 0xffffffff) >> HASH_SHIFT
      end

      # Number of equal bytes at s1 and s2 (s1 < s2), not reading past limit. Gallops
      # with byteslice comparisons (memcmp) to avoid per-byte loops on long matches.
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

      def emit_copy_upto64(out, offset, len)
        if len < 12 && offset < 2048
          out << (1 | ((len - 4) << 2) | ((offset >> 8) << 5)) << (offset & 0xff)
        else
          out << (2 | ((len - 1) << 2)) << (offset & 0xff) << (offset >> 8)
        end
      end

      private_class_method :read_varint, :write_varint, :compress_block, :hash32,
        :match_length, :emit_literal, :emit_copy, :emit_copy_upto64
    end
  end
end

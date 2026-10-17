# frozen_string_literal: true

module Herringbone
  module Codecs
    # Pure-Ruby Zstandard decompressor, so files written with ZSTD can be read without the
    # zstd-ruby gem. When zstd-ruby is loaded, Compression uses it instead; writing ZSTD still
    # needs it, as there is no compressor here.
    #
    # Written from RFC 8878. Dictionaries are not supported (Parquet does not use them).
    #
    # Every input is distrusted: output may never grow past the size the page header declares,
    # every loop either consumes input or produces bounded output, and malformed tables, offsets
    # and bitstreams raise Error instead of decoding garbage.
    #
    # @api private
    module Zstd
      # Raised for corrupt, truncated or unsupported Zstandard input, and for input that
      # decompresses to more than the expected size.
      class Error < StandardError; end

      # Little-endian magic number of a Zstandard frame
      MAGIC = 0xFD2FB528
      # Magic numbers 0x184D2A50..0x184D2A5F start a skippable frame
      SKIPPABLE_MAGIC = 0x184D2A50
      # No block may decompress to more than this, nor have a larger compressed body
      BLOCK_MAX = 128 * 1024
      # The output grows past this as it is decoded, so a page header claiming a huge size
      # cannot make us allocate it upfront
      PREALLOCATE_MAX = 1 << 22
      # Shorthand for Encoding::BINARY.
      BINARY = Encoding::BINARY

      # Literal length codes: baseline by code
      LL_BASE = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 28, 32, 40,
        48, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16_384, 32_768, 65_536].freeze
      # Extra bits of each literal length code
      LL_BITS = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3,
        4, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16].freeze
      # Match length codes: baseline by code
      ML_BASE = ((3..34).to_a + [35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051,
        4099, 8195, 16_387, 32_771, 65_539]).freeze
      # Extra bits of each match length code
      ML_BITS = ([0] * 32 + [1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]).freeze
      # Largest offset code; its value takes this many extra bits
      MAX_OFFSET_CODE = 31

      # Predefined FSE distributions (RFC 8878 section 3.1.1.3.2.2), with their accuracy logs
      LL_DEFAULT = [[4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2,
        1, 1, 1, 1, 1, -1, -1, -1, -1], 6].freeze
      # Predefined match length distribution and accuracy log
      ML_DEFAULT = [[1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1], 6].freeze
      # Predefined offset code distribution and accuracy log
      OF_DEFAULT = [[1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
        -1, -1, -1], 5].freeze

      module_function

      # Decompresses one or more concatenated Zstandard frames (skippable frames are ignored)
      #
      # @param input [String] compressed bytes
      # @param limit [Integer] the decompressed size expected, which the output may not exceed
      # @return [String] decompressed bytes in ASCII-8BIT
      # @raise [Error] if the input is corrupt, truncated, uses a dictionary or decompresses to
      #   more than +limit+ bytes
      def decompress(input, limit)
        src = (input.encoding == BINARY) ? input : input.b
        raise Error, "Zstandard input is empty, expected at least one frame" if src.empty?
        out = String.new(capacity: [limit, PREALLOCATE_MAX].min, encoding: BINARY)
        pos = 0
        while pos < src.bytesize
          raise Error, "Zstandard input ends inside a frame magic number at offset #{pos}" if src.bytesize - pos < 4
          magic = u32(src, pos)
          if magic & 0xFFFFFFF0 == SKIPPABLE_MAGIC
            raise Error, "Zstandard skippable frame at offset #{pos} is truncated" if src.bytesize - pos < 8
            pos += 8 + u32(src, pos + 4)
            raise Error, "Zstandard skippable frame runs past the end of the input" if pos > src.bytesize
          elsif magic == MAGIC
            pos = FrameDecoder.new(src, pos + 4, out, limit).decode
          else
            raise Error, format("Not Zstandard data: expected the frame magic number at offset %d, found 0x%08X", pos, magic)
          end
        end
        out
      end

      # @param src [String] binary string
      # @param pos [Integer] offset of the value
      # @return [Integer] the little-endian 32-bit value at +pos+
      def u32(src, pos)
        src.getbyte(pos) | (src.getbyte(pos + 1) << 8) | (src.getbyte(pos + 2) << 16) | (src.getbyte(pos + 3) << 24)
      end

      # Reads a stream backwards, from its last byte to its first, as FSE and Huffman streams are
      # written. The last byte holds a 1 bit marking where the stream starts. Reading past the
      # first byte yields zeros, and is remembered so the caller can tell the stream was too short.
      #
      # @api private
      class BackwardBits
        # @param src [String] binary input
        # @param start [Integer] offset of the stream's first byte
        # @param stop [Integer] offset just past its last byte
        # @raise [Error] if the stream is empty or its last byte has no start marker
        def initialize(src, start, stop)
          raise Error, "Zstandard bitstream is empty" if stop <= start
          last = src.getbyte(stop - 1)
          raise Error, "Zstandard bitstream does not end with a marker bit (last byte is 0)" if last == 0
          @src = src
          @start = start
          @pos = stop - 1
          @nbits = last.bit_length - 1
          @bits = last & ((1 << @nbits) - 1)
          @overflow = 0
        end

        # @param n [Integer] number of bits, at most 56
        # @return [Integer] the next +n+ bits, most significant first
        def read(n)
          return 0 if n == 0
          refill if @nbits < n
          if @nbits < n
            @overflow += n - @nbits
            @bits <<= n - @nbits
            @nbits = n
          end
          @nbits -= n
          value = @bits >> @nbits
          @bits &= (1 << @nbits) - 1
          value
        end

        # @param n [Integer] number of bits, at most 56
        # @return [Integer] the next +n+ bits, without consuming them
        def peek(n)
          refill if @nbits < n
          (@nbits < n) ? @bits << (n - @nbits) : @bits >> (@nbits - n)
        end

        # @param n [Integer] number of bits to consume, after a peek of at least +n+
        # @return [void]
        def skip(n)
          if @nbits < n
            @overflow += n - @nbits
            @bits = 0
            @nbits = 0
          else
            @nbits -= n
            @bits &= (1 << @nbits) - 1
          end
        end

        # @return [Boolean] whether more bits were read than the stream has
        def overflowed?
          @overflow > 0
        end

        # @return [Boolean] whether every bit was read, and no more
        def finished?
          @nbits == 0 && @pos == @start && @overflow == 0
        end

        private

        # @return [void]
        def refill
          while @nbits <= 48 && @pos > @start
            @pos -= 1
            @bits = (@bits << 8) | @src.getbyte(@pos)
            @nbits += 8
          end
        end
      end

      # An FSE decoding table: for each state, the symbol it decodes to and how to reach the
      # next state (read +nbits+ bits, add them to +base+)
      #
      # @api private
      FSETable = Struct.new(:log, :symbols, :nbits, :base)

      # A Huffman decoding table indexed by the next +max_bits+ bits of the stream
      #
      # @api private
      HuffmanTable = Struct.new(:max_bits, :symbols, :lengths)

      # Decodes one frame, appending its content to the output. Keeps what blocks of a frame
      # share: the repeat offsets and the tables later blocks may reuse.
      #
      # @api private
      class FrameDecoder
        # @param src [String] binary input
        # @param pos [Integer] offset just past the frame's magic number
        # @param out [String] binary output, appended to
        # @param limit [Integer] size +out+ may not exceed
        def initialize(src, pos, out, limit)
          @src = src
          @pos = pos
          @out = out
          @limit = limit
          @base = out.bytesize
          @reps = [1, 4, 8]
          @huffman = nil
          @ll_table = @of_table = @ml_table = nil
        end

        # @return [Integer] offset just past the frame
        # @raise [Error] for a corrupt or truncated frame, or one that would exceed the limit
        def decode
          content_size, checksum = read_frame_header
          if content_size && content_size > @limit - @out.bytesize
            raise Error, "Zstandard frame declares #{content_size} bytes of content, more than the " \
              "#{@limit - @out.bytesize} bytes left of the #{@limit} expected"
          end

          last = false
          until last
            need(3, "block header")
            header = @src.getbyte(@pos) | (@src.getbyte(@pos + 1) << 8) | (@src.getbyte(@pos + 2) << 16)
            @pos += 3
            last = header & 1 == 1
            size = header >> 3
            case (header >> 1) & 3
            when 0
              raise Error, "Zstandard raw block of #{size} bytes is larger than the #{BLOCK_MAX} allowed" if size > BLOCK_MAX
              need(size, "raw block")
              emit(size)
              @out << @src.byteslice(@pos, size)
              @pos += size
            when 1
              need(1, "RLE block")
              raise Error, "Zstandard RLE block of #{size} bytes is larger than the #{BLOCK_MAX} allowed" if size > BLOCK_MAX
              emit(size)
              @out << (@src.byteslice(@pos, 1) * size)
              @pos += 1
            when 2
              raise Error, "Zstandard compressed block of #{size} bytes is larger than the #{BLOCK_MAX} allowed" if size > BLOCK_MAX
              need(size, "compressed block")
              before = @out.bytesize
              decode_compressed_block(@pos, @pos + size)
              if @out.bytesize - before > BLOCK_MAX
                raise Error, "Zstandard block decompressed to #{@out.bytesize - before} bytes, more than the #{BLOCK_MAX} allowed"
              end
              @pos += size
            else
              raise Error, "Zstandard block at offset #{@pos - 3} has the reserved block type 3"
            end
          end

          produced = @out.bytesize - @base
          if content_size && produced != content_size
            raise Error, "Zstandard frame decompressed to #{produced} bytes, but its header declares #{content_size}"
          end
          if checksum
            need(4, "content checksum")
            expected = Zstd.u32(@src, @pos)
            actual = XXHash.xxh64(@out.byteslice(@base, produced)) & 0xFFFFFFFF
            raise Error, format("Zstandard content checksum mismatch: frame says %08x, content hashes to %08x", expected, actual) if expected != actual
            @pos += 4
          end
          @pos
        end

        private

        # @return [Array(Integer, Boolean)] the declared content size (nil when absent) and
        #   whether a content checksum follows the blocks
        def read_frame_header
          need(1, "frame header")
          descriptor = @src.getbyte(@pos)
          @pos += 1
          fcs_flag = descriptor >> 6
          single_segment = descriptor[5] == 1
          raise Error, "Zstandard frame header has the reserved bit set" if descriptor[3] == 1
          dict_id_size = [0, 1, 2, 4][descriptor & 3]
          fcs_size = [single_segment ? 1 : 0, 2, 4, 8][fcs_flag]

          header_size = (single_segment ? 0 : 1) + dict_id_size + fcs_size
          need(header_size, "frame header")
          @pos += 1 unless single_segment # window descriptor: we keep the whole output anyway
          if dict_id_size > 0
            dict_id = read_le(@pos, dict_id_size)
            if dict_id != 0
              raise Error, "Zstandard frame needs dictionary #{dict_id}, but dictionaries are not supported"
            end
            @pos += dict_id_size
          end
          content_size = (fcs_size > 0) ? read_le(@pos, fcs_size) : nil
          content_size += 256 if fcs_size == 2
          @pos += fcs_size
          [content_size, descriptor[2] == 1]
        end

        # @param pos [Integer] offset of the value
        # @param size [Integer] its size in bytes
        # @return [Integer] the little-endian unsigned value
        def read_le(pos, size)
          value = 0
          (size - 1).downto(0) { |i| value = (value << 8) | @src.getbyte(pos + i) }
          value
        end

        # @param n [Integer] bytes needed at the current position
        # @param what [String] what they are, for the message
        # @return [void]
        # @raise [Error] if the input has fewer
        def need(n, what)
          return if @src.bytesize - @pos >= n
          raise Error, "Zstandard #{what} at offset #{@pos} needs #{n} bytes, but only #{@src.bytesize - @pos} are left"
        end

        # @param n [Integer] bytes about to be appended to the output
        # @return [void]
        # @raise [Error] if they would take it past the limit
        def emit(n)
          return if @out.bytesize + n <= @limit
          raise Error, "Zstandard data decompresses to more than the #{@limit} bytes expected"
        end

        # @param pos [Integer] offset of the block body
        # @param stop [Integer] offset just past it
        # @return [void]
        def decode_compressed_block(pos, stop)
          literals, pos = read_literals(pos, stop)
          raise Error, "Zstandard block ends before its sequences section" if pos >= stop
          count = @src.getbyte(pos)
          pos += 1
          if count >= 128
            raise Error, "Zstandard sequence count is truncated" if pos >= stop
            if count == 255
              raise Error, "Zstandard sequence count is truncated" if pos + 2 > stop
              count = @src.getbyte(pos) + (@src.getbyte(pos + 1) << 8) + 0x7F00
              pos += 2
            else
              count = ((count - 128) << 8) + @src.getbyte(pos)
              pos += 1
            end
          end

          if count == 0
            raise Error, "Zstandard block has #{stop - pos} bytes after an empty sequences section" if pos != stop
            emit(literals.bytesize)
            @out << literals
            return
          end

          raise Error, "Zstandard sequences section has no compression modes byte" if pos >= stop
          modes = @src.getbyte(pos)
          pos += 1
          raise Error, "Zstandard sequences section sets reserved mode bits" if modes & 3 != 0
          @ll_table, pos = read_sequence_table(modes >> 6, pos, stop, @ll_table, LL_PREDEFINED, LL_BASE.size - 1, 9, "literal lengths")
          @of_table, pos = read_sequence_table((modes >> 4) & 3, pos, stop, @of_table, OF_PREDEFINED, MAX_OFFSET_CODE, 8, "offsets")
          @ml_table, pos = read_sequence_table((modes >> 2) & 3, pos, stop, @ml_table, ML_PREDEFINED, ML_BASE.size - 1, 9, "match lengths")
          execute_sequences(BackwardBits.new(@src, pos, stop), count, literals)
        end

        # @param mode [Integer] 0 predefined, 1 RLE, 2 FSE-compressed, 3 repeat
        # @param pos [Integer] offset of the table description
        # @param stop [Integer] end of the block
        # @param previous [FSETable, nil] the table of the previous block, for mode 3
        # @param default [FSETable] the predefined table, for mode 0
        # @param max_symbol [Integer] largest valid code
        # @param max_log [Integer] largest valid accuracy log
        # @param name [String] what the codes are, for messages
        # @return [Array(FSETable, Integer)] the table, and the offset after its description
        def read_sequence_table(mode, pos, stop, previous, default, max_symbol, max_log, name)
          case mode
          when 0
            [default, pos]
          when 1
            raise Error, "Zstandard RLE table for #{name} is truncated" if pos >= stop
            symbol = @src.getbyte(pos)
            raise Error, "Zstandard RLE table for #{name} uses code #{symbol}, the largest is #{max_symbol}" if symbol > max_symbol
            [FSETable.new(0, [symbol], [0], [0]), pos + 1]
          when 2
            counts, log, pos = Zstd.read_fse_counts(@src, pos, stop, max_symbol, max_log)
            [Zstd.build_fse_table(counts, log), pos]
          else
            raise Error, "Zstandard block repeats the #{name} table, but no earlier block has one" unless previous
            [previous, pos]
          end
        end

        # Decodes the sequences and copies their literals and matches to the output
        #
        # @param bits [BackwardBits] the sequences bitstream
        # @param count [Integer] number of sequences
        # @param literals [String] decoded literals, which the sequences copy from in order
        # @return [void]
        def execute_sequences(bits, count, literals)
          ll_t = @ll_table
          of_t = @of_table
          ml_t = @ml_table
          ll_state = bits.read(ll_t.log)
          of_state = bits.read(of_t.log)
          ml_state = bits.read(ml_t.log)
          r1, r2, r3 = @reps
          out = @out
          base = @base
          limit = @limit
          lit_pos = 0
          lit_size = literals.bytesize
          i = 0
          while i < count
            of_code = of_t.symbols[of_state]
            ll_code = ll_t.symbols[ll_state]
            ml_code = ml_t.symbols[ml_state]
            offset_value = (1 << of_code) + bits.read(of_code)
            match_len = ML_BASE[ml_code] + bits.read(ML_BITS[ml_code])
            lit_len = LL_BASE[ll_code] + bits.read(LL_BITS[ll_code])

            if offset_value > 3
              offset = offset_value - 3
              r3 = r2
              r2 = r1
              r1 = offset
            else
              case offset_value - ((lit_len == 0) ? 0 : 1)
              when 0
                offset = r1
              when 1
                offset = r2
                r2 = r1
                r1 = offset
              when 2
                offset = r3
                r3 = r2
                r2 = r1
                r1 = offset
              else
                offset = r1 - 1
                raise Error, "Zstandard sequence #{i} repeats an offset of 0" if offset == 0
                r3 = r2
                r2 = r1
                r1 = offset
              end
            end

            i += 1
            if i < count
              ll_state = ll_t.base[ll_state] + bits.read(ll_t.nbits[ll_state])
              ml_state = ml_t.base[ml_state] + bits.read(ml_t.nbits[ml_state])
              of_state = of_t.base[of_state] + bits.read(of_t.nbits[of_state])
            end
            raise Error, "Zstandard sequences bitstream is too short for #{count} sequences" if bits.overflowed?

            if lit_pos + lit_len > lit_size
              raise Error, "Zstandard sequence #{i - 1} needs #{lit_len} literals, but only #{lit_size - lit_pos} are left"
            end
            at = out.bytesize
            if at + lit_len + match_len > limit
              raise Error, "Zstandard data decompresses to more than the #{limit} bytes expected"
            end
            out << literals.byteslice(lit_pos, lit_len) if lit_len > 0
            lit_pos += lit_len
            at += lit_len
            if offset > at - base
              raise Error, "Zstandard sequence #{i - 1} copies from #{offset} bytes back, but the frame has only #{at - base} bytes so far"
            end
            if offset >= match_len
              out << out.byteslice(at - offset, match_len)
            else
              pattern = out.byteslice(at - offset, offset)
              out << (pattern * (match_len / offset)) << pattern.byteslice(0, match_len % offset)
            end
          end

          raise Error, "Zstandard sequences bitstream has bits left after #{count} sequences" unless bits.finished?
          @reps = [r1, r2, r3]
          rest = lit_size - lit_pos
          emit(rest)
          out << literals.byteslice(lit_pos, rest) if rest > 0
        end

        # @param pos [Integer] offset of the literals section
        # @param stop [Integer] end of the block
        # @return [Array(String, Integer)] the literals, and the offset just past the section
        def read_literals(pos, stop)
          raise Error, "Zstandard block is empty, expected a literals section" if pos >= stop
          b0 = @src.getbyte(pos)
          type = b0 & 3
          size_format = (b0 >> 2) & 3

          if type < 2
            header_size = [1, 2, 1, 3][size_format]
            raise Error, "Zstandard literals header is truncated" if pos + header_size > stop
            size = case header_size
            when 1 then b0 >> 3
            when 2 then (b0 >> 4) + (@src.getbyte(pos + 1) << 4)
            else (b0 >> 4) + (@src.getbyte(pos + 1) << 4) + (@src.getbyte(pos + 2) << 12)
            end
            raise Error, "Zstandard block has #{size} literals, more than the #{BLOCK_MAX} allowed" if size > BLOCK_MAX
            pos += header_size
            if type == 0
              raise Error, "Zstandard raw literals run past the end of the block" if pos + size > stop
              return [@src.byteslice(pos, size), pos + size]
            end
            raise Error, "Zstandard RLE literals are truncated" if pos >= stop
            return [@src.byteslice(pos, 1) * size, pos + 1]
          end

          header_size, size_bits, streams = [[3, 10, 1], [3, 10, 4], [4, 14, 4], [5, 18, 4]][size_format]
          raise Error, "Zstandard literals header is truncated" if pos + header_size > stop
          header = read_le(pos, header_size)
          mask = (1 << size_bits) - 1
          size = (header >> 4) & mask
          compressed_size = (header >> (4 + size_bits)) & mask
          raise Error, "Zstandard block has #{size} literals, more than the #{BLOCK_MAX} allowed" if size > BLOCK_MAX
          pos += header_size
          stop_literals = pos + compressed_size
          raise Error, "Zstandard compressed literals run past the end of the block" if stop_literals > stop

          if type == 2
            @huffman, pos = Zstd.read_huffman_table(@src, pos, stop_literals)
          elsif @huffman.nil?
            raise Error, "Zstandard block reuses the Huffman table, but no earlier block has one"
          end
          [Zstd.decode_huffman_literals(@huffman, @src, pos, stop_literals, size, streams), stop_literals]
        end
      end

      # Reads an FSE table description (RFC 8878 section 4.1.1)
      #
      # @param src [String] binary input
      # @param pos [Integer] offset of the description
      # @param stop [Integer] offset it may not reach past
      # @param max_symbol [Integer] largest valid symbol
      # @param max_log [Integer] largest valid accuracy log
      # @return [Array(Array<Integer>, Integer, Integer)] the normalized counts (-1 for "less than
      #   one"), the accuracy log, and the offset just past the description
      # @raise [Error] if the description is truncated or does not add up
      def read_fse_counts(src, pos, stop, max_symbol, max_log)
        bitpos = 0
        read_bits = lambda do |n|
          byte = pos + (bitpos >> 3)
          window = 0
          4.times { |i| window |= (src.getbyte(byte + i) || 0) << (8 * i) if byte + i < stop }
          (window >> (bitpos & 7)) & ((1 << n) - 1)
        end

        log = read_bits.call(4) + 5
        bitpos = 4
        raise Error, "Zstandard FSE table has accuracy log #{log}, the largest allowed here is #{max_log}" if log > max_log
        remaining = (1 << log) + 1
        threshold = 1 << log
        nbits = log + 1
        counts = []
        previous_zero = false

        while remaining > 1
          if previous_zero
            repeat = read_bits.call(2)
            bitpos += 2
            zeros = repeat
            while repeat == 3
              raise Error, "Zstandard FSE table has more zero counts than symbols" if counts.size + zeros > max_symbol
              repeat = read_bits.call(2)
              bitpos += 2
              zeros += repeat
            end
            raise Error, "Zstandard FSE table has more zero counts than symbols" if counts.size + zeros > max_symbol
            zeros.times { counts << 0 }
          end
          raise Error, "Zstandard FSE table has counts for more than #{max_symbol + 1} symbols" if counts.size > max_symbol

          max = 2 * threshold - 1 - remaining
          low = read_bits.call(nbits - 1)
          if low < max
            count = low
            bitpos += nbits - 1
          else
            count = read_bits.call(nbits)
            count -= max if count >= threshold
            bitpos += nbits
          end
          count -= 1
          remaining -= count.abs
          # Otherwise the loop below halves threshold down to 0 and spins forever
          raise Error, "Zstandard FSE table counts add up to more than #{1 << log}" if remaining < 1
          counts << count
          previous_zero = count == 0
          while remaining < threshold
            nbits -= 1
            threshold >>= 1
          end
        end

        used = (bitpos + 7) >> 3
        raise Error, "Zstandard FSE table description runs past its end" if pos + used > stop
        [counts, log, pos + used]
      end

      # Spreads normalized counts over a decoding table (RFC 8878 section 4.1.1)
      #
      # @param counts [Array<Integer>] normalized count per symbol, -1 for "less than one"
      # @param log [Integer] accuracy log; the counts' magnitudes add up to 2**log
      # @return [FSETable]
      def build_fse_table(counts, log)
        size = 1 << log
        symbols = Array.new(size)
        high = size - 1
        counts.each_with_index do |count, symbol|
          next unless count == -1
          symbols[high] = symbol
          high -= 1
        end

        step = (size >> 1) + (size >> 3) + 3
        mask = size - 1
        position = 0
        counts.each_with_index do |count, symbol|
          count.times do
            symbols[position] = symbol
            position = (position + step) & mask
            position = (position + step) & mask while position > high
          end
        end
        raise Error, "Zstandard FSE table counts do not fill the table" unless position == 0

        next_state = counts.map { |count| (count == -1) ? 1 : count }
        nbits = Array.new(size)
        base = Array.new(size)
        size.times do |state|
          symbol = symbols[state]
          n = next_state[symbol]
          next_state[symbol] += 1
          nbits[state] = log - (n.bit_length - 1)
          base[state] = (n << nbits[state]) - size
        end
        FSETable.new(log, symbols, nbits, base)
      end

      # Reads a Huffman tree description (RFC 8878 section 4.2.1)
      #
      # @param src [String] binary input
      # @param pos [Integer] offset of the description
      # @param stop [Integer] offset it may not reach past
      # @return [Array(HuffmanTable, Integer)] the table, and the offset just past the description
      def read_huffman_table(src, pos, stop)
        raise Error, "Zstandard Huffman tree description is missing" if pos >= stop
        header = src.getbyte(pos)
        pos += 1
        if header >= 128
          count = header - 127
          size = (count + 1) / 2
          raise Error, "Zstandard Huffman weights run past the end of the literals" if pos + size > stop
          weights = Array.new(count) do |i|
            byte = src.getbyte(pos + i / 2)
            i.even? ? byte >> 4 : byte & 15
          end
          pos += size
        else
          raise Error, "Zstandard Huffman weights have a compressed size of 0" if header == 0
          raise Error, "Zstandard Huffman weights run past the end of the literals" if pos + header > stop
          weights = decode_huffman_weights(src, pos, pos + header)
          pos += header
        end
        [build_huffman_table(weights), pos]
      end

      # Decodes FSE-compressed Huffman weights: two states take turns over one bitstream until
      # it runs out
      #
      # @param src [String] binary input
      # @param pos [Integer] offset of the compressed weights
      # @param stop [Integer] offset just past them
      # @return [Array<Integer>] the weights
      def decode_huffman_weights(src, pos, stop)
        counts, log, pos = read_fse_counts(src, pos, stop, 15, 6)
        table = build_fse_table(counts, log)
        bits = BackwardBits.new(src, pos, stop)
        states = [bits.read(log), bits.read(log)]
        weights = []
        turn = 0
        while true
          raise Error, "Zstandard Huffman weights describe more than 255 symbols" if weights.size >= 255
          state = states[turn]
          weights << table.symbols[state]
          states[turn] = table.base[state] + bits.read(table.nbits[state])
          if bits.overflowed?
            raise Error, "Zstandard Huffman weights describe more than 255 symbols" if weights.size >= 255
            weights << table.symbols[states[1 - turn]]
            break
          end
          turn = 1 - turn
        end
        weights
      end

      # Builds the decoding table from the weights of all symbols but the last, whose weight is
      # implied by the others
      #
      # @param weights [Array<Integer>] weight per symbol, 0 for unused symbols
      # @return [HuffmanTable]
      def build_huffman_table(weights)
        total = weights.sum { |w| (w > 0) ? 1 << (w - 1) : 0 }
        raise Error, "Zstandard Huffman tree has no weights" if total == 0
        max_bits = total.bit_length
        raise Error, "Zstandard Huffman codes would be #{max_bits} bits long, the most allowed is 11" if max_bits > 11
        rest = (1 << max_bits) - total
        raise Error, "Zstandard Huffman weights do not form a complete tree" unless rest & (rest - 1) == 0
        weights += [rest.bit_length]

        size = 1 << max_bits
        symbols = Array.new(size)
        lengths = Array.new(size)
        position = 0
        1.upto(max_bits) do |w|
          span = 1 << (w - 1)
          length = max_bits + 1 - w
          weights.each_with_index do |weight, symbol|
            next unless weight == w
            symbols.fill(symbol, position, span)
            lengths.fill(length, position, span)
            position += span
          end
        end
        HuffmanTable.new(max_bits, symbols, lengths)
      end

      # @param table [HuffmanTable]
      # @param src [String] binary input
      # @param pos [Integer] offset of the stream(s), after the tree description
      # @param stop [Integer] offset just past the last stream
      # @param size [Integer] number of literals
      # @param streams [Integer] 1, or 4 with a jump table in front
      # @return [String] the literals
      def decode_huffman_literals(table, src, pos, stop, size, streams)
        return decode_huffman_stream(table, src, pos, stop, size) if streams == 1

        raise Error, "Zstandard literals jump table is truncated" if pos + 6 > stop
        sizes = Array.new(3) { |i| src.getbyte(pos + 2 * i) | (src.getbyte(pos + 2 * i + 1) << 8) }
        pos += 6
        sizes << stop - pos - sizes.sum
        raise Error, "Zstandard literals jump table points past the end of the literals" if sizes.last < 1
        segment = (size + 3) / 4
        raise Error, "Zstandard block has too few literals (#{size}) for 4 streams" if size < 3 * segment
        out = String.new(capacity: size, encoding: BINARY)
        sizes.each_with_index do |stream_size, i|
          count = (i < 3) ? segment : size - 3 * segment
          out << decode_huffman_stream(table, src, pos, pos + stream_size, count)
          pos += stream_size
        end
        out
      end

      # @param table [HuffmanTable]
      # @param src [String] binary input
      # @param pos [Integer] offset of the stream
      # @param stop [Integer] offset just past it
      # @param count [Integer] number of literals it holds
      # @return [String] the literals
      def decode_huffman_stream(table, src, pos, stop, count)
        bits = BackwardBits.new(src, pos, stop)
        max_bits = table.max_bits
        symbols = table.symbols
        lengths = table.lengths
        decoded = Array.new(count) do
          index = bits.peek(max_bits)
          bits.skip(lengths[index])
          symbols[index]
        end
        raise Error, "Zstandard Huffman stream is too short for #{count} literals" if bits.overflowed?
        raise Error, "Zstandard Huffman stream has bits left after #{count} literals" unless bits.finished?
        decoded.pack("C*")
      end

      # Tables for the predefined distributions, built once
      LL_PREDEFINED = Ractor.make_shareable(build_fse_table(*LL_DEFAULT))
      # Predefined match length table
      ML_PREDEFINED = Ractor.make_shareable(build_fse_table(*ML_DEFAULT))
      # Predefined offset code table
      OF_PREDEFINED = Ractor.make_shareable(build_fse_table(*OF_DEFAULT))
    end
  end
end

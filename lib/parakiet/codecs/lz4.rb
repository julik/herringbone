# frozen_string_literal: true

module Parakiet
  module Codecs
    # Pure-Ruby LZ4: raw block format (Parquet LZ4_RAW), Hadoop-framed blocks
    # (Parquet's deprecated LZ4) and a decoder for the LZ4 frame format.
    module LZ4
      class Error < StandardError; end

      MIN_MATCH = 4
      LAST_LITERALS = 5 # the last 5 bytes of a block are always literals
      MFLIMIT = 12      # the last match must start at least 12 bytes before the end
      MAX_OFFSET = 65_535
      HASH_LOG = 14
      HASH_SHIFT = 32 - HASH_LOG
      SKIP_STRENGTH = 6
      FRAME_MAGIC = 0x184D2204
      HADOOP_PREFIX = 8
      BINARY = Encoding::BINARY
      # String#unpack1 accepts offset: since Ruby 3.1
      UNPACK_OFFSET = begin
        "\x00\x00\x00\x00".unpack1("V", offset: 0)
        true
      rescue ArgumentError
        false
      end

      module_function

      # Decompress a raw LZ4 block that must expand to exactly uncompressed_size bytes.
      def decompress_block(input, uncompressed_size)
        src = binary(input)
        out = String.new(capacity: uncompressed_size, encoding: BINARY)
        decode_block(src, 0, src.bytesize, out, uncompressed_size)
        unless out.bytesize == uncompressed_size
          raise Error, "LZ4 block decoded to #{out.bytesize} bytes, expected #{uncompressed_size}"
        end
        out
      end

      # Parquet LZ4 (codec 5). Tries Hadoop framing, then the LZ4 frame format,
      # then a bare raw block (Arrow falls back hadoop -> raw; some writers emitted frames).
      def decompress_hadoop(input, uncompressed_size)
        src = binary(input)
        result = try_hadoop(src, uncompressed_size)
        return result if result

        if src.bytesize >= 4 && src.unpack1("V") == FRAME_MAGIC
          begin
            out = decompress_frame(src, uncompressed_size)
            return out if out.bytesize == uncompressed_size
          rescue Error
            # fall through to raw block
          end
        end
        decompress_block(src, uncompressed_size)
      end

      # Decode LZ4 frame format data (one or more frames, skippable frames ignored).
      # Checksums are skipped, not verified.
      def decompress_frame(input, max_size)
        src = binary(input)
        n = src.bytesize
        out = String.new(capacity: max_size, encoding: BINARY)
        ip = 0
        while ip < n
          raise Error, "Truncated LZ4 frame header" if ip + 4 > n
          magic = le32(src, ip)
          if (magic & 0xFFFFFFF0) == 0x184D2A50 # skippable frame
            raise Error, "Truncated skippable frame" if ip + 8 > n
            ip += 8 + le32(src, ip + 4)
            next
          end
          raise Error, "Bad LZ4 frame magic 0x#{magic.to_s(16)}" unless magic == FRAME_MAGIC
          ip = decode_frame(src, ip + 4, n, out, max_size)
        end
        raise Error, "Truncated skippable frame" if ip > n
        out
      end

      # Compress into a single raw LZ4 block.
      def compress_block(input)
        src = binary(input)
        n = src.bytesize
        out = String.new(capacity: n + (n / 255) + 16, encoding: BINARY)
        anchor = 0

        if n > MFLIMIT
          table = Array.new(1 << HASH_LOG, -1)
          mflimit = n - MFLIMIT
          match_limit = n - LAST_LITERALS
          ip = 0
          while ip < mflimit
            seq = UNPACK_OFFSET ? src.unpack1("V", offset: ip) : u32(src, ip)
            h = ((seq * 40_503) & 0xFFFFFFFF) >> HASH_SHIFT
            ref = table[h]
            table[h] = ip

            if ref < 0 || ip - ref > MAX_OFFSET ||
                seq != (UNPACK_OFFSET ? src.unpack1("V", offset: ref) : u32(src, ref))
              ip += 1 + ((ip - anchor) >> SKIP_STRENGTH)
              next
            end

            # Extend the match backwards into pending literals
            while ip > anchor && ref > 0 && src.getbyte(ip - 1) == src.getbyte(ref - 1)
              ip -= 1
              ref -= 1
            end

            # Extend forwards, 8 bytes at a time where possible
            len = MIN_MATCH
            if UNPACK_OFFSET
              while ip + len + 8 <= match_limit &&
                  src.unpack1("Q<", offset: ip + len) == src.unpack1("Q<", offset: ref + len)
                len += 8
              end
            end
            len += 1 while ip + len < match_limit && src.getbyte(ip + len) == src.getbyte(ref + len)

            # Emit the sequence: token, literal run, offset, extended match length
            lit_len = ip - anchor
            ml = len - MIN_MATCH
            out << (((lit_len < 15 ? lit_len : 15) << 4) | (ml < 15 ? ml : 15))
            write_length(out, lit_len - 15) if lit_len >= 15
            out << src.byteslice(anchor, lit_len) if lit_len > 0
            offset = ip - ref
            out << (offset & 0xFF) << (offset >> 8)
            write_length(out, ml - 15) if ml >= 15

            ip += len
            anchor = ip
            break if ip >= mflimit

            # Seed the table with a position inside the match for better follow-up matches
            p2 = ip - 2
            s2 = UNPACK_OFFSET ? src.unpack1("V", offset: p2) : u32(src, p2)
            table[((s2 * 40_503) & 0xFFFFFFFF) >> HASH_SHIFT] = p2
          end
        end

        emit_last_literals(out, src, anchor, n - anchor)
        out
      end

      # Single Hadoop-framed block: [BE uncompressed size][BE compressed size][raw block]
      def compress_hadoop(input)
        src = binary(input)
        block = compress_block(src)
        [src.bytesize, block.bytesize].pack("NN") << block
      end

      # -- internals --

      def binary(str)
        str.encoding == BINARY ? str : str.b
      end

      def le32(src, i)
        src.byteslice(i, 4).unpack1("V")
      end

      def u32(src, i)
        src.getbyte(i) | (src.getbyte(i + 1) << 8) | (src.getbyte(i + 2) << 16) | (src.getbyte(i + 3) << 24)
      end

      def write_length(out, len)
        if len >= 255
          out << ("\xFF".b * (len / 255))
          len %= 255
        end
        out << len
      end

      def emit_last_literals(out, src, anchor, lit_len)
        out << ((lit_len < 15 ? lit_len : 15) << 4)
        write_length(out, lit_len - 15) if lit_len >= 15
        out << src.byteslice(anchor, lit_len) if lit_len > 0
      end

      # Decode one raw block from src[ip...iend], appending to out (which may already
      # hold earlier data that matches can reference). out may not grow beyond limit.
      def decode_block(src, ip, iend, out, limit)
        while ip < iend
          token = src.getbyte(ip)
          ip += 1

          lit = token >> 4
          if lit == 15
            while true
              raise Error, "Truncated LZ4 literal length" if ip >= iend
              b = src.getbyte(ip)
              ip += 1
              lit += b
              break if b != 255
            end
          end
          if lit > 0
            raise Error, "LZ4 literals run past end of input" if ip + lit > iend
            raise Error, "LZ4 output exceeds expected size" if out.bytesize + lit > limit
            out << src.byteslice(ip, lit)
            ip += lit
          end
          break if ip == iend # last sequence carries literals only

          raise Error, "Truncated LZ4 match offset" if ip + 2 > iend
          offset = src.getbyte(ip) | (src.getbyte(ip + 1) << 8)
          ip += 2
          olen = out.bytesize
          raise Error, "Invalid LZ4 match offset #{offset}" if offset == 0 || offset > olen

          mlen = token & 15
          if mlen == 15
            while true
              raise Error, "Truncated LZ4 match length" if ip >= iend
              b = src.getbyte(ip)
              ip += 1
              mlen += b
              break if b != 255
            end
          end
          mlen += MIN_MATCH
          raise Error, "LZ4 output exceeds expected size" if olen + mlen > limit

          pos = olen - offset
          if mlen <= offset
            out << out.byteslice(pos, mlen)
          else
            # Overlapping match: the pattern of length `offset` repeats
            pattern = out.byteslice(pos, offset)
            reps, rem = mlen.divmod(offset)
            out << (pattern * reps)
            out << pattern.byteslice(0, rem) if rem > 0
          end
        end
        ip
      end

      # Arrow-compatible Hadoop frame parsing; returns nil if the data does not fit the framing.
      def try_hadoop(src, uncompressed_size)
        n = src.bytesize
        return nil if n < HADOOP_PREFIX

        out = String.new(capacity: uncompressed_size, encoding: BINARY)
        ip = 0
        while n - ip >= HADOOP_PREFIX
          expected, csize = src.byteslice(ip, HADOOP_PREFIX).unpack("NN")
          ip += HADOOP_PREFIX
          return nil if csize > n - ip
          return nil if out.bytesize + expected > uncompressed_size

          target = out.bytesize + expected
          begin
            decode_block(src, ip, ip + csize, out, target)
          rescue Error
            return nil
          end
          return nil unless out.bytesize == target
          ip += csize
        end
        return nil unless ip == n && out.bytesize == uncompressed_size
        out
      end

      def decode_frame(src, ip, n, out, limit)
        raise Error, "Truncated LZ4 frame descriptor" if ip + 3 > n
        flg = src.getbyte(ip)
        raise Error, "Unsupported LZ4 frame version" unless (flg >> 6) == 1
        raise Error, "LZ4 frames with dictionaries are not supported" if flg & 0x01 != 0
        block_checksum = flg & 0x10 != 0
        content_size = flg & 0x08 != 0
        content_checksum = flg & 0x04 != 0
        ip += 2 # FLG, BD
        ip += 8 if content_size
        ip += 1 # header checksum
        raise Error, "Truncated LZ4 frame descriptor" if ip > n

        while true
          raise Error, "Truncated LZ4 frame block header" if ip + 4 > n
          bsize = le32(src, ip)
          ip += 4
          break if bsize == 0 # EndMark

          uncompressed = bsize & 0x80000000 != 0
          bsize &= 0x7FFFFFFF
          raise Error, "LZ4 frame block runs past end of input" if ip + bsize > n
          if uncompressed
            raise Error, "LZ4 output exceeds expected size" if out.bytesize + bsize > limit
            out << src.byteslice(ip, bsize)
          else
            decode_block(src, ip, ip + bsize, out, limit)
          end
          ip += bsize
          ip += 4 if block_checksum
        end
        ip += 4 if content_checksum
        raise Error, "Truncated LZ4 frame" if ip > n
        ip
      end

      private_class_method :binary, :le32, :u32, :write_length, :emit_last_literals,
        :decode_block, :try_hadoop, :decode_frame
    end
  end
end

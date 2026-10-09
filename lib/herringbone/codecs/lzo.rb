# frozen_string_literal: true

module Herringbone
  module Codecs
    # Pure-Ruby LZO1X decompressor, for reading Parquet files written by parquet-mr with
    # hadoop-lzo. There is no compressor: nothing but hadoop-lzo writes LZO, and nothing
    # outside the JVM reads it.
    #
    # Written from the bitstream description in the Linux kernel's
    # Documentation/staging/lzo.rst, not from the (GPL) LZO sources.
    #
    # @api private
    module LZO
      # Raised for corrupt or truncated LZO input.
      class Error < StandardError; end

      # Hadoop block header: big-endian 32-bit uncompressed size of the block.
      HADOOP_BLOCK_PREFIX = 4
      # Hadoop chunk header: big-endian 32-bit compressed size of the chunk.
      HADOOP_CHUNK_PREFIX = 4
      # Shorthand for Encoding::BINARY.
      BINARY = Encoding::BINARY

      module_function

      # Parquet LZO (codec 3). hadoop-lzo writes Hadoop block framing; data that does not fit
      # the framing is decoded as one bare LZO1X stream.
      # @param input [String] compressed page data
      # @param uncompressed_size [Integer] exact decompressed size, from the page header
      # @return [String] decompressed bytes in ASCII-8BIT
      # @raise [Error] if neither layout decodes
      def decompress_hadoop(input, uncompressed_size)
        src = binary(input)
        try_hadoop(src, uncompressed_size) || decompress_block(src, uncompressed_size)
      end

      # Decompress one bare LZO1X stream that must expand to exactly uncompressed_size bytes.
      # @param input [String] LZO1X stream, ending with the end-of-stream marker
      # @param uncompressed_size [Integer] exact decompressed size
      # @return [String] decompressed bytes in ASCII-8BIT
      # @raise [Error] if the stream is corrupt or does not decode to +uncompressed_size+ bytes
      def decompress_block(input, uncompressed_size)
        src = binary(input)
        out = String.new(capacity: uncompressed_size, encoding: BINARY)
        ip = decode_block(src, 0, src.bytesize, out, uncompressed_size)
        raise Error, "#{src.bytesize - ip} bytes after the end of the LZO stream" unless ip == src.bytesize
        unless out.bytesize == uncompressed_size
          raise Error, "LZO stream decoded to #{out.bytesize} bytes, expected #{uncompressed_size}"
        end
        out
      end

      # @param str [String] input in any encoding
      # @return [String] +str+ itself if already binary, otherwise a binary copy
      def binary(str)
        (str.encoding == BINARY) ? str : str.b
      end

      # Hadoop's BlockCompressorStream layout: blocks of (uncompressed size, then chunks of
      # (compressed size, LZO stream) until the block is filled). Each chunk is a separate stream.
      # @param src [String] binary input
      # @param uncompressed_size [Integer] exact decompressed size expected over all blocks
      # @return [String, nil] decompressed bytes, or nil if +src+ is not valid Hadoop-framed LZO
      def try_hadoop(src, uncompressed_size)
        n = src.bytesize
        out = String.new(capacity: uncompressed_size, encoding: BINARY)
        ip = 0
        while ip < n
          return nil if n - ip < HADOOP_BLOCK_PREFIX
          block_end = out.bytesize + src.byteslice(ip, HADOOP_BLOCK_PREFIX).unpack1("N")
          ip += HADOOP_BLOCK_PREFIX
          return nil if block_end > uncompressed_size

          while out.bytesize < block_end
            return nil if n - ip < HADOOP_CHUNK_PREFIX
            csize = src.byteslice(ip, HADOOP_CHUNK_PREFIX).unpack1("N")
            ip += HADOOP_CHUNK_PREFIX
            return nil if csize > n - ip
            begin
              return nil unless decode_block(src, ip, ip + csize, out, block_end) == ip + csize
            rescue Error
              return nil
            end
            ip += csize
          end
        end
        (out.bytesize == uncompressed_size) ? out : nil
      end

      # Decode one LZO1X stream from src[ip...iend], appending to out. Matches may only reach
      # back to where this stream's output starts. out may not grow beyond limit.
      #
      # Every instruction is a match optionally followed by 0-3 literals (its low two bits, the
      # "state"), or a run of 4+ literals. What an instruction byte below 16 means depends on
      # the state the previous instruction left behind.
      # @param src [String] binary input
      # @param ip [Integer] offset of the stream in +src+
      # @param iend [Integer] offset just past the stream
      # @param out [String] binary output buffer, appended to
      # @param limit [Integer] maximum total byte size of +out+
      # @return [Integer] input offset just past the end-of-stream marker
      # @raise [Error] if the stream is truncated, has an invalid distance or overflows +limit+
      def decode_block(src, ip, iend, out, limit)
        base = out.bytesize
        raise Error, "Empty LZO stream" if ip >= iend

        state = 0
        t = src.getbyte(ip)
        if t > 17 # the first byte may open with a literal run of its own
          ip += 1
          state = t - 17
          ip = copy_literals(src, ip, iend, out, limit, state)
          state = 4 if state > 4
        end

        while true
          raise Error, "Truncated LZO stream" if ip >= iend
          t = src.getbyte(ip)
          ip += 1

          if t < 16
            if state == 0
              len = t + 3
              len, ip = extended_length(src, ip, iend, 18) if t == 0
              ip = copy_literals(src, ip, iend, out, limit, len)
              state = 4
              next
            end
            raise Error, "Truncated LZO stream" if ip >= iend
            dist = (src.getbyte(ip) << 2) + (t >> 2) + 1
            ip += 1
            if state == 4
              dist += 2048
              len = 3
            else
              len = 2
            end
            s = t & 3
          elsif t < 32
            len = (t & 7) + 2
            len, ip = extended_length(src, ip, iend, 9) if t & 7 == 0
            raise Error, "Truncated LZO stream" if ip + 2 > iend
            le = src.getbyte(ip) | (src.getbyte(ip + 1) << 8)
            ip += 2
            dist = ((t & 8) << 11) + (le >> 2)
            return ip if dist == 0 # end of stream
            dist += 16_384
            s = le & 3
          elsif t < 64
            len = (t & 31) + 2
            len, ip = extended_length(src, ip, iend, 33) if t & 31 == 0
            raise Error, "Truncated LZO stream" if ip + 2 > iend
            le = src.getbyte(ip) | (src.getbyte(ip + 1) << 8)
            ip += 2
            dist = (le >> 2) + 1
            s = le & 3
          else
            raise Error, "Truncated LZO stream" if ip >= iend
            len = (t >> 5) + 1 # 3-4 bytes for 01LDDDSS, 5-8 for 1LLDDDSS
            dist = (src.getbyte(ip) << 3) + ((t >> 2) & 7) + 1
            ip += 1
            s = t & 3
          end

          copy_match(out, base, dist, len, limit)
          ip = copy_literals(src, ip, iend, out, limit, s) if s > 0
          state = s
        end
      end

      # Reads a length extension: a byte of 0 for each 255, then the nonzero remainder.
      # @param src [String] binary input
      # @param ip [Integer] offset of the first extension byte
      # @param iend [Integer] offset just past the stream
      # @param bias [Integer] added to the extension
      # @return [Array(Integer, Integer)] the length, and the offset just past the extension
      # @raise [Error] if the extension runs past +iend+
      def extended_length(src, ip, iend, bias)
        len = bias
        while true
          raise Error, "Truncated LZO length" if ip >= iend
          b = src.getbyte(ip)
          ip += 1
          return [len + b, ip] unless b == 0
          len += 255
        end
      end

      # @param src [String] binary input
      # @param ip [Integer] offset of the literals in +src+
      # @param iend [Integer] offset just past the stream
      # @param out [String] binary output buffer, appended to
      # @param limit [Integer] maximum total byte size of +out+
      # @param len [Integer] number of literal bytes
      # @return [Integer] offset just past the literals
      # @raise [Error] if the literals run past +iend+ or +out+ would exceed +limit+
      def copy_literals(src, ip, iend, out, limit, len)
        raise Error, "LZO literals run past end of input" if ip + len > iend
        raise Error, "LZO output exceeds expected size" if out.bytesize + len > limit
        out << src.byteslice(ip, len)
        ip + len
      end

      # @param out [String] binary output buffer, appended to
      # @param base [Integer] size of +out+ when the current stream started
      # @param dist [Integer] how far back the match starts
      # @param len [Integer] match length, which may exceed +dist+ (a repeating pattern)
      # @param limit [Integer] maximum total byte size of +out+
      # @return [String] +out+
      # @raise [Error] if the match reaches before the stream's output or +out+ would exceed +limit+
      def copy_match(out, base, dist, len, limit)
        pos = out.bytesize
        raise Error, "LZO match distance #{dist} reaches before start of output" if dist > pos - base
        raise Error, "LZO output exceeds expected size" if pos + len > limit
        if dist >= len
          out << out.byteslice(pos - dist, len)
        else
          pattern = out.byteslice(pos - dist, dist)
          out << (pattern * (len / dist)) << pattern.byteslice(0, len % dist)
        end
      end

      private_class_method :binary, :try_hadoop, :decode_block, :extended_length, :copy_literals, :copy_match
    end
  end
end

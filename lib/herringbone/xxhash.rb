# frozen_string_literal: true

module Herringbone
  # XXH64 (seed 0), the hash Parquet bloom filters use.
  #
  # When the optional "xxhash" gem (a C extension) can be loaded it is used, which is 20-40x
  # faster; otherwise hashing is pure Ruby. The gem is only a speedup, so nothing fails without
  # it. +XXHash.backend = :ruby+ forces pure Ruby (for tests and benchmarks).
  #
  # The pure-Ruby version keeps every 64-bit value as two 32-bit halves, and multiplies by the
  # XXH64 primes split into 16-bit pieces, so that no intermediate result leaves the Fixnum range.
  # Masked 64-bit Integer arithmetic is shorter, but allocates a Bignum for almost every operation
  # (about 25 per hash), and with a large live heap (a writer holding a row group) those
  # allocations trigger so many garbage collections that hashing becomes up to 10x slower. The
  # arithmetic is written once with the small code generators below, whose output is inlined into
  # the hashing methods: no method calls or allocations in the hot paths.
  module XXHash
    # 64-bit mask
    M = 0xFFFF_FFFF_FFFF_FFFF
    # XXH64 PRIME64_1
    P1 = 11_400_714_785_074_694_791
    # XXH64 PRIME64_2
    P2 = 14_029_467_366_897_019_727
    # XXH64 PRIME64_3
    P3 = 1_609_587_929_392_839_161
    # XXH64 PRIME64_4
    P4 = 9_650_029_242_287_828_579
    # XXH64 PRIME64_5
    P5 = 2_870_177_450_012_600_261
    # 32-bit mask
    M32 = 0xFFFF_FFFF
    # unpack format splitting the input into little-endian 32-bit words
    WORDS = "V*" # frozen, unlike a literal in the generated code

    # Gem providing the native implementation
    NATIVE_GEM = "xxhash"

    # Code generators for the pure-Ruby hash: each returns Ruby source operating on a 64-bit
    # value held in two local variables (+hi+ and +lo+, 32 bits each), using t0/t1 as scratch
    module Generator
      module_function

      # Shifts are written as multiplications and divisions by powers of two, which YARV has
      # specialized instructions for (<< and >> on Integers are method calls).
      #
      # (hi:lo) = (hi:lo) * c mod 2^64. Products are at most 48 bits wide: the low halves are
      # multiplied by 16-bit pieces of c, and only the low 32 bits of the cross terms are kept.
      #
      # @param hi [String] variable holding the high 32 bits
      # @param lo [String] variable holding the low 32 bits
      # @param c [Integer] unsigned 64-bit constant multiplier
      # @param hi_zero [Boolean] whether +hi+ is known to be 0, which drops its cross terms
      # @return [String] Ruby source (uses t0 and t1 as scratch)
      def mul(hi, lo, c, hi_zero: false)
        ch = c >> 32
        cl = c & M32
        cross = "#{lo} * #{ch & 0xFFFF} + (#{lo} * #{ch >> 16} & 0xFFFF) * 65536"
        cross += " + #{hi} * #{cl & 0xFFFF} + (#{hi} * #{cl >> 16} & 0xFFFF) * 65536" unless hi_zero
        <<~RUBY
          t1 = #{lo} * #{cl >> 16}
          t0 = #{lo} * #{cl & 0xFFFF} + (t1 & 0xFFFF) * 65536
          #{hi} = (t0 / 4294967296 + t1 / 65536 + #{cross}) & 0xFFFFFFFF
          #{lo} = t0 & 0xFFFFFFFF
        RUBY
      end

      # Rotate (hi:lo) left by r bits (0 < r < 32)
      #
      # @param hi [String] variable holding the high 32 bits
      # @param lo [String] variable holding the low 32 bits
      # @param r [Integer] rotation in bits, 1..31
      # @return [String] Ruby source (uses t0 as scratch)
      def rotl(hi, lo, r)
        mask = (1 << (32 - r)) - 1
        <<~RUBY
          t0 = #{hi}
          #{hi} = (#{hi} & #{mask}) * #{1 << r} | #{lo} / #{1 << (32 - r)}
          #{lo} = (#{lo} & #{mask}) * #{1 << r} | t0 / #{1 << (32 - r)}
        RUBY
      end

      # (hi:lo) += (a_hi:a_lo), where the addend is two expressions (constants or variables)
      #
      # @param hi [String] variable holding the high 32 bits
      # @param lo [String] variable holding the low 32 bits
      # @param a_hi [String, Integer] expression for the addend's high 32 bits
      # @param a_lo [String, Integer] expression for the addend's low 32 bits
      # @return [String] Ruby source
      def add(hi, lo, a_hi, a_lo)
        <<~RUBY
          #{lo} += #{a_lo}
          #{hi} = (#{hi} + #{a_hi} + #{lo} / 4294967296) & 0xFFFFFFFF
          #{lo} &= 0xFFFFFFFF
        RUBY
      end

      # (hi:lo) += c, mod 2^64
      #
      # @param hi [String] variable holding the high 32 bits
      # @param lo [String] variable holding the low 32 bits
      # @param c [Integer] unsigned 64-bit constant addend
      # @return [String] Ruby source
      def add_const(hi, lo, c)
        add(hi, lo, c >> 32, c & M32)
      end

      # Assigns the 64-bit constant c to (hi:lo)
      #
      # @param hi [String] variable for the high 32 bits
      # @param lo [String] variable for the low 32 bits
      # @param c [Integer] unsigned 64-bit constant
      # @return [String] Ruby source
      def set(hi, lo, c)
        "#{hi} = #{c >> 32}\n#{lo} = #{c & M32}\n"
      end

      # XXH64 round with a zero accumulator: (hi:lo) = rotl(lane * P2, 31) * P1
      #
      # @param hi [String] variable holding the lane's high 32 bits, replaced by the result's
      # @param lo [String] variable holding the lane's low 32 bits, replaced by the result's
      # @return [String] Ruby source
      def round0(hi, lo)
        mul(hi, lo, P2) + rotl(hi, lo, 31) + mul(hi, lo, P1)
      end

      # Stripe round: acc = rotl(acc + lane * P2, 31) * P1, with the lane in (xh:xl)
      #
      # @param hi [String] variable holding the accumulator's high 32 bits
      # @param lo [String] variable holding the accumulator's low 32 bits
      # @param xh [String] variable holding the lane's high 32 bits (clobbered)
      # @param xl [String] variable holding the lane's low 32 bits (clobbered)
      # @return [String] Ruby source
      def round(hi, lo, xh, xl)
        mul(xh, xl, P2) + add(hi, lo, xh, xl) + rotl(hi, lo, 31) + mul(hi, lo, P1)
      end

      # h ^= rotl(v * P2, 31) * P1; h = h * P1 + P4, with v in (vh:vl) (left unchanged)
      #
      # @param hi [String] variable holding h's high 32 bits
      # @param lo [String] variable holding h's low 32 bits
      # @param vh [String] variable holding the accumulator v's high 32 bits
      # @param vl [String] variable holding the accumulator v's low 32 bits
      # @return [String] Ruby source (uses xh and xl as scratch)
      def merge_round(hi, lo, vh, vl)
        "xh = #{vh}\nxl = #{vl}\n" + round0("xh", "xl") +
          "#{hi} ^= xh\n#{lo} ^= xl\n" + mul(hi, lo, P1) + add_const(hi, lo, P4)
      end

      # Consumes an 8-byte lane in (xh:xl)
      #
      # @param hi [String] variable holding the hash's high 32 bits
      # @param lo [String] variable holding the hash's low 32 bits
      # @return [String] Ruby source
      def lane8(hi, lo)
        round0("xh", "xl") + "#{hi} ^= xh\n#{lo} ^= xl\n" + rotl(hi, lo, 27) + mul(hi, lo, P1) + add_const(hi, lo, P4)
      end

      # Consumes a 4-byte word in xl
      #
      # @param hi [String] variable holding the hash's high 32 bits
      # @param lo [String] variable holding the hash's low 32 bits
      # @return [String] Ruby source (sets xh)
      def lane4(hi, lo)
        "xh = 0\n" + mul("xh", "xl", P1, hi_zero: true) + "#{hi} ^= xh\n#{lo} ^= xl\n" +
          rotl(hi, lo, 23) + mul(hi, lo, P2) + add_const(hi, lo, P3)
      end

      # Consumes one byte in xl (as it is below 2^16, byte * P5 needs no splitting)
      #
      # @param hi [String] variable holding the hash's high 32 bits
      # @param lo [String] variable holding the hash's low 32 bits
      # @return [String] Ruby source
      def lane1(hi, lo)
        <<~RUBY + rotl(hi, lo, 11) + mul(hi, lo, P1)
          t0 = xl * #{P5 & M32}
          #{hi} ^= (t0 / 4294967296 + xl * #{P5 >> 32}) & 0xFFFFFFFF
          #{lo} ^= t0 & 0xFFFFFFFF
        RUBY
      end

      # Final mix; evaluates to the hash as one Integer
      #
      # @param hi [String] variable holding the hash's high 32 bits
      # @param lo [String] variable holding the hash's low 32 bits
      # @return [String] Ruby source whose last expression is the 64-bit hash
      def avalanche(hi, lo)
        "#{lo} ^= #{hi} / 2\n" + mul(hi, lo, P2) +
          "#{lo} ^= (#{hi} & 0x1FFFFFFF) * 8 | #{lo} / 536870912\n#{hi} ^= #{hi} / 536870912\n" +
          mul(hi, lo, P3) + "#{lo} ^= #{hi}\n(#{hi} << 32) | #{lo}\n"
      end

      # Source of the pure-Ruby hashing methods, evaluated into XXHash: +ruby_xxh64(bytes)+,
      # +ruby_xxh64_lane(xh, xl)+ (8 bytes as two 32-bit halves) and +ruby_xxh64_u32(xl)+ (4 bytes)
      #
      # @return [String] Ruby source defining the three singleton methods
      def source
        g = self
        <<~RUBY
          # XXH64 of 8 bytes given as two little-endian 32-bit halves
          def self.ruby_xxh64_lane(xh, xl)
            #{g.set("h", "l", P5 + 8)}
            #{g.lane8("h", "l")}
            #{g.avalanche("h", "l")}
          end

          # XXH64 of 4 bytes given as a little-endian 32-bit word
          def self.ruby_xxh64_u32(xl)
            #{g.set("h", "l", P5 + 4)}
            #{g.lane4("h", "l")}
            #{g.avalanche("h", "l")}
          end

          def self.ruby_xxh64(bytes)
            len = bytes.bytesize
            words = bytes.unpack(WORDS)
            i = 0
            if len >= 32
              #{g.set("ah", "al", (P1 + P2) & M)}
              #{g.set("bh", "bl", P2)}
              ch = 0
              cl = 0
              #{g.set("dh", "dl", (-P1) & M)}
              limit = (len >> 5) << 3
              while i < limit
                xl = words[i]
                xh = words[i + 1]
                #{g.round("ah", "al", "xh", "xl")}
                xl = words[i + 2]
                xh = words[i + 3]
                #{g.round("bh", "bl", "xh", "xl")}
                xl = words[i + 4]
                xh = words[i + 5]
                #{g.round("ch", "cl", "xh", "xl")}
                xl = words[i + 6]
                xh = words[i + 7]
                #{g.round("dh", "dl", "xh", "xl")}
                i += 8
              end
              h = ah
              l = al
              #{g.rotl("h", "l", 1)}
              yh = bh
              yl = bl
              #{g.rotl("yh", "yl", 7)}
              #{g.add("h", "l", "yh", "yl")}
              yh = ch
              yl = cl
              #{g.rotl("yh", "yl", 12)}
              #{g.add("h", "l", "yh", "yl")}
              yh = dh
              yl = dl
              #{g.rotl("yh", "yl", 18)}
              #{g.add("h", "l", "yh", "yl")}
              #{g.merge_round("h", "l", "ah", "al")}
              #{g.merge_round("h", "l", "bh", "bl")}
              #{g.merge_round("h", "l", "ch", "cl")}
              #{g.merge_round("h", "l", "dh", "dl")}
              #{g.add("h", "l", 0, "len")}
            else
              #{g.set("h", "l", P5)}
              #{g.add("h", "l", 0, "len")}
            end
            nwords = words.size
            while i + 2 <= nwords
              xl = words[i]
              xh = words[i + 1]
              #{g.lane8("h", "l")}
              i += 2
            end
            if i < nwords
              xl = words[i]
              #{g.lane4("h", "l")}
              i += 1
            end
            pos = i << 2
            while pos < len
              xl = bytes.getbyte(pos)
              #{g.lane1("h", "l")}
              pos += 1
            end
            #{g.avalanche("h", "l")}
          end
        RUBY
      end
    end

    module_eval(Generator.source, __FILE__, __LINE__)

    @native = nil # nil: not resolved yet, false: pure Ruby, else the native module
    @native_lib = nil

    class << self
      # XXH64 of a String's bytes, as an unsigned 64-bit Integer
      #
      # @param bytes [String] data to hash (its encoding is ignored)
      # @return [Integer] the hash, 0...2^64
      def xxh64(bytes)
        native = @native
        native = resolve_backend if native.nil?
        native ? native.xxh64(bytes, 0) : ruby_xxh64(bytes)
      end

      # XXH64 of 8 bytes given as a little-endian 64-bit Integer (an INT64 or DOUBLE's PLAIN
      # encoding), signed or unsigned: only its low 64 bits are used
      #
      # @param lane [Integer] value whose low 64 bits are hashed
      # @return [Integer] the hash, 0...2^64
      def xxh64_u64(lane)
        native = @native
        native = resolve_backend if native.nil?
        return native.xxh64([lane].pack("Q<"), 0) if native
        ruby_xxh64_lane((lane >> 32) & M32, lane & M32)
      end

      # XXH64 of 4 bytes given as a little-endian 32-bit Integer (INT32, FLOAT), signed or unsigned
      #
      # @param word [Integer] value whose low 32 bits are hashed
      # @return [Integer] the hash, 0...2^64
      def xxh64_u32(word)
        native = @native
        native = resolve_backend if native.nil?
        return native.xxh64([word].pack("L<"), 0) if native
        ruby_xxh64_u32(word & M32)
      end

      # Hashes of many 64-bit Integers (low 64 bits of each)
      #
      # @param lanes [Array<Integer>] values to hash, signed or unsigned
      # @return [Array<Integer>] the hashes, in the same order
      def xxh64_u64_all(lanes)
        native = @native
        native = resolve_backend if native.nil?
        if native
          packed = lanes.pack("Q<*")
          Array.new(lanes.size) { |i| native.xxh64(packed.byteslice(i << 3, 8), 0) }
        else
          lanes.map { |v| ruby_xxh64_lane(v / 4_294_967_296 & M32, v & M32) }
        end
      end

      # Hashes of many 32-bit Integers (low 32 bits of each)
      #
      # @param words [Array<Integer>] values to hash, signed or unsigned
      # @return [Array<Integer>] the hashes, in the same order
      def xxh64_u32_all(words)
        native = @native
        native = resolve_backend if native.nil?
        if native
          packed = words.pack("L<*")
          Array.new(words.size) { |i| native.xxh64(packed.byteslice(i << 2, 4), 0) }
        else
          words.map { |v| ruby_xxh64_u32(v & M32) }
        end
      end

      # Hashes of many Strings
      #
      # @param strings [Array<String>] values whose bytes are hashed
      # @return [Array<Integer>] the hashes, in the same order
      def xxh64_all(strings)
        native = @native
        native = resolve_backend if native.nil?
        native ? strings.map { |s| native.xxh64(s, 0) } : strings.map { |s| ruby_xxh64(s) }
      end

      # :native when the xxhash gem is used, :ruby otherwise
      #
      # @return [Symbol] +:native+ or +:ruby+
      def backend
        native = @native
        native = resolve_backend if native.nil?
        native ? :native : :ruby
      end

      # :ruby forces pure Ruby, :native requires the xxhash gem (UnsupportedError if it cannot be
      # loaded), nil goes back to the default: native when available
      #
      # @param name [Symbol, nil] +:ruby+, +:native+ or nil
      # @return [void]
      # @raise [UnsupportedError] for +:native+ when the gem cannot be loaded
      # @raise [ArgumentError] for any other name
      def backend=(name)
        @native = case name
        when :ruby then false
        when :native
          native_library || raise(UnsupportedError, "The \"#{NATIVE_GEM}\" gem could not be loaded")
        when nil then nil
        else raise ArgumentError, "Unknown XXHash backend #{name.inspect} (expected :ruby, :native or nil)"
        end
      end

      # Whether the native xxhash gem can be loaded (whatever the selected backend)
      #
      # @return [Boolean] true when the gem is loadable
      def native_available?
        !!native_library
      end

      private

      # Picks the default backend on first use: native when the gem loads, pure Ruby otherwise
      #
      # @return [Module, false] the native module, or false for pure Ruby
      def resolve_backend
        @native = native_library || false
      end

      # Requires the xxhash gem once and memoizes the result (a failed require is not retried)
      #
      # @return [Module, false] the gem's module to call +xxh64(data, seed)+ on, or false when it
      #   cannot be loaded
      def native_library
        if @native_lib.nil?
          @native_lib = begin
            require NATIVE_GEM
            defined?(::XXhash::XXhashInternal) ? ::XXhash::XXhashInternal : ::XXhash
          rescue LoadError
            false
          end
        end
        @native_lib
      end
    end
  end
end

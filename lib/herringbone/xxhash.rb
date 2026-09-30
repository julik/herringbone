# frozen_string_literal: true

module Herringbone
  # Pure-Ruby XXH64 (seed 0), the hash Parquet bloom filters use.
  #
  # Ruby Integers become Bignums above 2**62, so 64-bit arithmetic is done on Integers masked
  # with 2**64 - 1. That was measured against splitting values into 32-bit halves (with the
  # constants split further so that no product leaves the Fixnum range): the extra Ruby operations
  # of the split version cost more than the short-lived two-word Bignums, which MRI handles
  # quickly (about 1.6x slower for the multiplications). The hot paths are inlined by hand.
  module XXHash
    M = 0xFFFF_FFFF_FFFF_FFFF
    P1 = 11_400_714_785_074_694_791
    P2 = 14_029_467_366_897_019_727
    P3 = 1_609_587_929_392_839_161
    P4 = 9_650_029_242_287_828_579
    P5 = 2_870_177_450_012_600_261

    module_function

    # XXH64 of a String's bytes, as an unsigned 64-bit Integer
    def xxh64(bytes)
      len = bytes.bytesize
      pos = 0
      if len >= 32
        v1 = (P1 + P2) & M
        v2 = P2
        v3 = 0
        v4 = (-P1) & M
        limit = len - 32
        while pos <= limit
          a, b, c, d = bytes.byteslice(pos, 32).unpack("Q<4")
          v1 = (v1 + a * P2) & M
          v1 = (((v1 << 31) | (v1 >> 33)) & M) * P1 & M
          v2 = (v2 + b * P2) & M
          v2 = (((v2 << 31) | (v2 >> 33)) & M) * P1 & M
          v3 = (v3 + c * P2) & M
          v3 = (((v3 << 31) | (v3 >> 33)) & M) * P1 & M
          v4 = (v4 + d * P2) & M
          v4 = (((v4 << 31) | (v4 >> 33)) & M) * P1 & M
          pos += 32
        end
        h = ((((v1 << 1) | (v1 >> 63)) & M) + (((v2 << 7) | (v2 >> 57)) & M) +
          (((v3 << 12) | (v3 >> 52)) & M) + (((v4 << 18) | (v4 >> 46)) & M)) & M
        h = merge_round(h, v1)
        h = merge_round(h, v2)
        h = merge_round(h, v3)
        h = merge_round(h, v4)
        h = (h + len) & M
      else
        h = (P5 + len) & M
      end
      while pos + 8 <= len
        k = bytes.byteslice(pos, 8).unpack1("Q<") * P2 & M
        k = (((k << 31) | (k >> 33)) & M) * P1 & M
        h ^= k
        h = ((((h << 27) | (h >> 37)) & M) * P1 + P4) & M
        pos += 8
      end
      if pos + 4 <= len
        h ^= bytes.byteslice(pos, 4).unpack1("L<") * P1 & M
        h = ((((h << 23) | (h >> 41)) & M) * P2 + P3) & M
        pos += 4
      end
      while pos < len
        h ^= bytes.getbyte(pos) * P5 & M
        h = (((h << 11) | (h >> 53)) & M) * P1 & M
        pos += 1
      end
      avalanche(h)
    end

    # XXH64 of 8 bytes given as an unsigned little-endian 64-bit Integer (an INT64 or DOUBLE's
    # PLAIN encoding), without building a String
    def xxh64_u64(lane)
      k = lane * P2 & M
      k = (((k << 31) | (k >> 33)) & M) * P1 & M
      h = (P5 + 8) ^ k
      h = ((((h << 27) | (h >> 37)) & M) * P1 + P4) & M
      avalanche(h)
    end

    # XXH64 of 4 bytes given as an unsigned little-endian 32-bit Integer (INT32, FLOAT)
    def xxh64_u32(word)
      h = (P5 + 4) ^ (word * P1 & M)
      h = ((((h << 23) | (h >> 41)) & M) * P2 + P3) & M
      avalanche(h)
    end

    def merge_round(h, v)
      k = v * P2 & M
      k = (((k << 31) | (k >> 33)) & M) * P1 & M
      h ^= k
      (h * P1 + P4) & M
    end

    def avalanche(h)
      h ^= h >> 33
      h = h * P2 & M
      h ^= h >> 29
      h = h * P3 & M
      h ^ (h >> 32)
    end
  end
end

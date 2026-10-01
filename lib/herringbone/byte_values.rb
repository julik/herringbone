# frozen_string_literal: true

module Herringbone
  # Compact buffer for the values of a BYTE_ARRAY or FIXED_LEN_BYTE_ARRAY column while a row
  # group is being collected. Instead of holding on to one Ruby String per value, it either
  #
  # * dictionary-encodes values as they arrive (keeping each distinct value once, plus an Integer
  #   index per value), which suits low-cardinality columns such as enums and statuses, or
  # * appends the raw bytes to one binary String (plus a length per value for BYTE_ARRAY).
  #
  # It starts out in dictionary mode (when allowed) and switches to raw bytes once the dictionary
  # grows too large or too many values turn out to be distinct. Strings are only rebuilt when the
  # row group is flushed, one column at a time.
  class ByteValues
    # Values in the dictionary may take this many bytes before switching to raw bytes
    MAX_DICTIONARY_BYTES = 1024 * 1024
    # After this many values, give up on the dictionary if more than half of them are distinct
    CARDINALITY_CHECK_AT = 4096

    # Whether String#append_as_bytes (Ruby 3.4+) is available for appending without re-encoding
    APPEND_AS_BYTES = "".respond_to?(:append_as_bytes)

    # @param width [Integer, nil] byte length of each value for FIXED_LEN_BYTE_ARRAY, nil for BYTE_ARRAY
    # @param dictionary [Boolean] start in dictionary mode; false appends raw bytes from the start
    def initialize(width: nil, dictionary: true)
      @width = width
      @bytes = String.new(encoding: Encoding::BINARY)
      @lengths = width ? nil : []
      @count = 0
      if dictionary
        @dictionary = {}
        @dictionary_bytes = 0
        @indices = []
      end
    end

    # @return [Integer] number of values held
    def size
      @indices ? @indices.size : @count
    end

    # @return [Boolean] true when no values are held
    def empty? = size.zero?

    # @return [Boolean] true while still dictionary-encoding (not yet switched to raw bytes)
    def dictionary? = !@indices.nil?

    # Appends a value, switching to raw bytes when the dictionary limits are exceeded.
    # @param value [String] bytes of the value; for FIXED_LEN_BYTE_ARRAY it must be +width+ bytes
    #   long (not checked here)
    # @return [ByteValues] self
    def <<(value)
      if @indices
        index = @dictionary[value]
        if index.nil?
          if @dictionary_bytes + value.bytesize > MAX_DICTIONARY_BYTES
            switch_to_bytes
            return append_bytes(value)
          end
          # Hash#[]= stores a frozen copy of unfrozen String keys
          index = @dictionary.size
          @dictionary[value] = index
          @dictionary_bytes += value.bytesize + 4
        end
        @indices << index
        switch_to_bytes if @indices.size == CARDINALITY_CHECK_AT && @dictionary.size > CARDINALITY_CHECK_AT / 2
        self
      else
        append_bytes(value)
      end
    end

    # Removes the last value
    # @return [void]
    def pop
      truncate(size - 1) unless size.zero?
    end

    # Supports the `slice!(n..)` form used to roll back a failed row
    # @param range [Range] endless range; values from +range.begin+ on are dropped
    # @return [void]
    def slice!(range)
      truncate(range.begin)
    end

    # Approximate memory held, used to size row groups
    # @return [Integer] estimated bytes
    def memory_bytes
      if @indices
        # Each distinct value is a String object plus a Hash entry
        @indices.size * 8 + @dictionary_bytes + @dictionary.size * 48
      else
        @bytes.bytesize + (@lengths ? @lengths.size * 8 : 0)
      end
    end

    # Returns [:dictionary, values, indices] when the column is worth dictionary-encoding,
    # otherwise [:plain, values]
    #
    # Dictionary encoding is kept unless there are more than 16 values and more than about half
    # of them are distinct.
    # @return [Array(Symbol, Array<String>, Array<Integer>), Array(Symbol, Array<String>)]
    #   distinct values and an index per value, or all values in order
    def materialize
      if @indices
        keys = @dictionary.keys
        return [:dictionary, keys, @indices] unless keys.size > @indices.size / 2 + 1 && @indices.size > 16
        return [:plain, @indices.map { |i| keys[i] }]
      end
      [:plain, strings]
    end

    private

    # Appends +value+ in raw-bytes mode, recording its length for BYTE_ARRAY.
    # @param value [String] bytes of the value, in any encoding
    # @return [ByteValues] self
    def append_bytes(value)
      if value.encoding == Encoding::BINARY || value.ascii_only?
        @bytes << value
      elsif APPEND_AS_BYTES
        @bytes.append_as_bytes(value)
      else
        @bytes << value.b
      end
      @lengths << value.bytesize if @lengths
      @count += 1
      self
    end

    # Leaves dictionary mode, re-appending every value held so far as raw bytes.
    # @return [void]
    def switch_to_bytes
      keys = @dictionary.keys
      indices = @indices
      @indices = @dictionary = nil
      indices.each { |i| append_bytes(keys[i]) }
    end

    # Drops all values after the first +n+.
    # @param n [Integer] number of values to keep
    # @return [void]
    def truncate(n)
      if @indices
        @indices.slice!(n..)
      else
        keep = if @lengths
          @lengths.slice!(n..)
          @lengths.sum
        else
          n * @width
        end
        @bytes.slice!(keep..)
        @count = n
      end
    end

    # Splits the raw bytes back into one binary String per value.
    # @return [Array<String>]
    def strings
      if @lengths
        pos = 0
        @lengths.map do |len|
          s = @bytes.byteslice(pos, len)
          pos += len
          s
        end
      else
        Array.new(@count) { |i| @bytes.byteslice(i * @width, @width) }
      end
    end
  end
end

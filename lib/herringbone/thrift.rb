# frozen_string_literal: true

module Herringbone
  # Minimal Thrift Compact Protocol implementation, just enough for Parquet metadata.
  # Structs are described declaratively (see Herringbone::Thrift::Struct) so that
  # both the reader and the writer are driven by the same field tables.
  #
  # @api private
  module Thrift
    # Raised on malformed or truncated Thrift data, and on values the writer cannot encode
    class Error < StandardError; end

    # Compact protocol wire type: end of a struct's fields
    T_STOP = 0
    # Compact protocol wire type: boolean true (the value lives in the field header)
    T_TRUE = 1
    # Compact protocol wire type: boolean false (the value lives in the field header)
    T_FALSE = 2
    # Compact protocol wire type: signed 8-bit integer, one raw byte
    T_BYTE = 3
    # Compact protocol wire type: 16-bit integer, zigzag varint
    T_I16 = 4
    # Compact protocol wire type: 32-bit integer, zigzag varint
    T_I32 = 5
    # Compact protocol wire type: 64-bit integer, zigzag varint
    T_I64 = 6
    # Compact protocol wire type: little-endian IEEE 754 double, 8 bytes
    T_DOUBLE = 7
    # Compact protocol wire type: varint length followed by raw bytes
    T_BINARY = 8
    # Compact protocol wire type: list (size and element type header, then the elements)
    T_LIST = 9
    # Compact protocol wire type: set (encoded like a list)
    T_SET = 10
    # Compact protocol wire type: map (only skipped, Parquet metadata has none)
    T_MAP = 11
    # Compact protocol wire type: nested struct, terminated by T_STOP
    T_STRUCT = 12

    # Declared field types used in struct definitions
    # :bool, :byte, :i16, :i32, :i64, :double, :binary, :string, [:list, elem], StructClass
    #
    # Maps the scalar declared types to the wire type written for them. +:bool+ maps to T_TRUE,
    # but the writer picks T_TRUE or T_FALSE from the value.
    WIRE_TYPES = {
      bool: T_TRUE, byte: T_BYTE, i16: T_I16, i32: T_I32, i64: T_I64,
      double: T_DOUBLE, binary: T_BINARY, string: T_BINARY
    }.freeze

    # Values each declared integer type can hold, whatever width it came in on the wire
    INT_RANGES = {
      byte: -2**7...2**7, i16: -2**15...2**15, i32: -2**31...2**31, i64: -2**63...2**63
    }.freeze

    # Deepest nesting of structs, lists, sets and maps read or skipped, as in Apache Thrift
    MAX_DEPTH = 64

    # Wire type written for a declared field type
    #
    # @param type [Symbol, Array, Class] a scalar type from WIRE_TYPES, a +[:list, elem]+ Array,
    #   or a Struct subclass
    # @return [Integer] one of the T_* wire type constants (T_TRUE for +:bool+)
    # @raise [KeyError] for an unknown scalar type Symbol
    def self.wire_type_for(type)
      case type
      when Symbol then WIRE_TYPES.fetch(type)
      when Array then T_LIST
      else T_STRUCT
      end
    end

    # Whether a value of wire type +wire+ can be read as declared +type+
    #
    # Integer widths are interchangeable (any of i16/i32/i64 on the wire is read for any declared
    # integer type), and a set is accepted where a list is declared.
    #
    # @param wire [Integer] wire type from the field or list header
    # @param type [Symbol, Array, Class] declared field type (see WIRE_TYPES)
    # @return [Boolean] true when the value can be decoded as +type+, false when it must be skipped
    def self.compatible?(wire, type)
      case type
      when :bool then wire == T_TRUE || wire == T_FALSE
      when :byte then wire == T_BYTE
      when :i16, :i32, :i64 then wire == T_I16 || wire == T_I32 || wire == T_I64
      when :double then wire == T_DOUBLE
      when :binary, :string then wire == T_BINARY
      when Array then wire == T_LIST || wire == T_SET
      else wire == T_STRUCT
      end
    end

    # Decodes compact protocol data from a String, keeping a byte position into it
    class Reader
      # @return [Integer] byte offset of the next byte to read
      attr_reader :pos

      # @param buf [String] the encoded data (binary)
      # @param pos [Integer] byte offset to start reading at
      # @raise [Error] when +pos+ is negative
      def initialize(buf, pos = 0)
        raise Error, "Negative offset #{pos}" if pos.negative?
        @buf = buf
        @pos = pos
        @depth = 0
      end

      # Reads one raw byte
      #
      # @return [Integer] the byte, 0..255
      # @raise [Error] at the end of the buffer
      def read_byte
        b = @buf.getbyte(@pos)
        raise Error, "Unexpected end of Thrift data at #{@pos}" unless b
        @pos += 1
        b
      end

      # Reads an unsigned LEB128 varint
      #
      # @return [Integer] the decoded non-negative value, below 2**64
      # @raise [Error] when the varint runs past the buffer, is longer than 10 bytes or does not
      #   fit in 64 bits
      def read_varint
        result = 0
        shift = 0
        while true
          b = read_byte
          result |= (b & 0x7F) << shift
          if b < 0x80
            raise Error, "Varint exceeds 64 bits" if result >= 2**64
            return result
          end
          shift += 7
          raise Error, "Varint too long" if shift > 63
        end
      end

      # Reads a zigzag-encoded varint (how i16, i32, i64 and field id deltas are stored)
      #
      # @return [Integer] the decoded signed value
      # @raise [Error] when the varint runs past the buffer
      def read_zigzag
        n = read_varint
        (n >> 1) ^ -(n & 1)
      end

      # Reads a length-prefixed byte string
      #
      # @return [String] a slice of the buffer (with the buffer's encoding)
      # @raise [Error] when the length runs past the end of the buffer
      def read_binary
        len = read_varint
        raise Error, "Binary length #{len} exceeds buffer" if @pos + len > @buf.bytesize
        s = @buf.byteslice(@pos, len)
        @pos += len
        s
      end

      # Reads an 8-byte little-endian double
      #
      # @return [Float] the value
      # @raise [Error] when fewer than 8 bytes are left
      def read_double
        raise Error, "Unexpected end of Thrift data at #{@pos}" if @pos + 8 > @buf.bytesize
        v = @buf.byteslice(@pos, 8).unpack1("E")
        @pos += 8
        v
      end

      # Reads a struct of the given class, returning an instance.
      #
      # Fields the class does not declare, or whose wire type does not match the declared type,
      # are skipped, so newer writers' additions do not break reading.
      #
      # @param klass [Class] a Thrift::Struct subclass
      # @return [Struct] an instance of +klass+ with the fields that were present set
      # @raise [Error] on truncated or malformed data, or nesting deeper than MAX_DEPTH
      def read_struct(klass)
        nested do
          obj = klass.new
          fields = klass.fields_by_id
          last_id = 0
          while true
            header = read_byte
            wire = header & 0x0F
            break if wire == T_STOP
            delta = header >> 4
            fid = delta.zero? ? read_zigzag : last_id + delta
            last_id = fid
            field = fields[fid]
            if field && Thrift.compatible?(wire, field.type)
              obj.instance_variable_set(field.ivar, read_value(wire, field.type))
            else
              skip(wire)
            end
          end
          obj
        end
      end

      # Reads one value of wire type +wire+ as declared +type+
      #
      # @param wire [Integer] wire type from the field or list header
      # @param type [Symbol, Array, Class] declared type; +:string+ makes binary values UTF-8 and
      #   +:binary+ makes them BINARY, an Array or Struct subclass gives the element type or struct to read
      # @return [Object] true/false, an Integer (bytes are signed), a Float, a String, an Array
      #   (or nil, see #read_list) or a Struct
      # @raise [Error] on an unsupported wire type, truncated data or an integer out of the range
      #   of +type+
      def read_value(wire, type)
        case wire
        when T_TRUE then true
        when T_FALSE then false
        when T_BYTE
          b = read_byte
          (b >= 0x80) ? b - 0x100 : b
        when T_I16, T_I32, T_I64
          n = read_zigzag
          raise Error, "Integer #{n} out of range for #{type}" unless INT_RANGES.fetch(type).cover?(n)
          n
        when T_DOUBLE then read_double
        when T_BINARY
          s = read_binary
          s.force_encoding((type == :string) ? Encoding::UTF_8 : Encoding::BINARY)
        when T_LIST, T_SET then read_list(type)
        when T_STRUCT then read_struct(type)
        else
          raise Error, "Unsupported wire type #{wire}"
        end
      end

      # Reads a list or set, whose header holds the size (or 15 and a varint size) and the
      # element wire type
      #
      # @param type [Array] declared list type, +[:list, elem_type]+
      # @return [Array, nil] the elements, or nil (with the list skipped) when the element wire
      #   type does not match +elem_type+
      # @raise [Error] on truncated or malformed data, or nesting deeper than MAX_DEPTH
      def read_list(type)
        nested do
          header = read_byte
          size = header >> 4
          size = read_size if size == 15
          elem_wire = header & 0x0F
          elem_type = type[1]
          bool_elems = elem_wire == T_TRUE || elem_wire == T_FALSE
          if size.positive? && !(bool_elems && elem_type == :bool) && !Thrift.compatible?(elem_wire, elem_type)
            size.times { bool_elems ? read_byte : skip(elem_wire) }
            return nil
          end
          Array.new(size) do
            if elem_wire == T_TRUE || elem_wire == T_FALSE
              # Booleans inside lists are encoded as full bytes
              read_byte == T_TRUE
            else
              read_value(elem_wire, elem_type)
            end
          end
        end
      end

      # Advances past a value of wire type +wire+ without decoding it
      #
      # @param wire [Integer] wire type of the value to skip
      # @return [void]
      # @raise [Error] on an unknown wire type (including T_STOP), truncated data or nesting deeper
      #   than MAX_DEPTH
      def skip(wire)
        case wire
        when T_TRUE, T_FALSE then nil
        when T_BYTE then read_byte
        when T_I16, T_I32, T_I64 then read_varint
        when T_DOUBLE then read_double
        when T_BINARY then read_binary
        when T_LIST, T_SET
          nested do
            header = read_byte
            size = header >> 4
            size = read_size if size == 15
            elem = header & 0x0F
            size.times { (elem == T_TRUE || elem == T_FALSE) ? read_byte : skip(elem) }
          end
        when T_MAP
          nested do
            size = read_size
            unless size.zero?
              kv = read_byte
              size.times do
                [kv >> 4, kv & 0x0F].each { |w| (w == T_TRUE || w == T_FALSE) ? read_byte : skip(w) }
              end
            end
          end
        when T_STRUCT
          nested do
            while true
              header = read_byte
              w = header & 0x0F
              break if w == T_STOP
              read_zigzag if (header >> 4).zero?
              skip(w)
            end
          end
        else
          raise Error, "Cannot skip wire type #{wire}"
        end
      end

      private

      # Reads the element count of a list, set or map
      #
      # Every element takes at least one byte, so a count above the bytes left is corrupt. Checking
      # that up front keeps a forged count from preallocating a huge Array or skipping for ever.
      #
      # @return [Integer] the count, at most the number of bytes left in the buffer
      # @raise [Error] when the count exceeds the bytes left
      def read_size
        size = read_varint
        left = @buf.bytesize - @pos
        raise Error, "Collection of #{size} elements exceeds the #{left} bytes left" if size > left
        size
      end

      # Runs the block one nesting level deeper
      #
      # @yieldreturn [Object] the value read inside the nested container
      # @return [Object] the block's value
      # @raise [Error] when the nesting gets deeper than MAX_DEPTH
      def nested
        @depth += 1
        raise Error, "Thrift data nested deeper than #{MAX_DEPTH} levels" if @depth > MAX_DEPTH
        yield
      ensure
        @depth -= 1
      end
    end

    # Encodes compact protocol data by appending to a binary String
    class Writer
      # @return [String] the encoded data so far
      attr_reader :buf

      # @param buf [String] binary String to append to
      def initialize(buf = String.new(capacity: 1024, encoding: Encoding::BINARY))
        @buf = buf
      end

      # Writes an unsigned LEB128 varint
      #
      # @param n [Integer] non-negative value
      # @return [void]
      # @raise [Error] when +n+ is negative
      def write_varint(n)
        raise Error, "Negative varint" if n.negative?
        while n >= 0x80
          @buf << ((n & 0x7F) | 0x80)
          n >>= 7
        end
        @buf << n
      end

      # Writes a signed integer as a zigzag varint
      #
      # @param n [Integer] signed value
      # @return [void]
      def write_zigzag(n)
        write_varint(n.negative? ? ((-n) << 1) - 1 : n << 1)
      end

      # Writes a length-prefixed byte string
      #
      # @param s [String] value whose bytes are written (in any encoding)
      # @return [void]
      def write_binary(s)
        write_varint(s.bytesize)
        @buf << s.b
      end

      # Writes the non-nil fields of a struct in field id order, then T_STOP. Field ids are
      # written as a delta in the header when it is 1..15, else as a separate zigzag varint.
      # Booleans are carried by the header's wire type alone.
      #
      # @param obj [Struct] instance of a Thrift::Struct subclass
      # @return [void]
      def write_struct(obj)
        last_id = 0
        obj.class.fields.each do |field|
          value = obj.instance_variable_get(field.ivar)
          next if value.nil?
          wire = if field.type == :bool
            value ? T_TRUE : T_FALSE
          else
            Thrift.wire_type_for(field.type)
          end
          delta = field.id - last_id
          if delta.positive? && delta <= 15
            @buf << ((delta << 4) | wire)
          else
            @buf << wire
            write_zigzag(field.id)
          end
          last_id = field.id
          write_value(field.type, value) unless field.type == :bool
        end
        @buf << T_STOP
      end

      # Writes one value of a declared type. Not for +:bool+, whose value goes in a field or
      # list header (see #write_struct and #write_list).
      #
      # @param type [Symbol, Array, Class] declared type (see WIRE_TYPES)
      # @param value [Object] Integer, Float, String, Array or Struct matching +type+
      # @return [void]
      # @raise [Error] when an integer type gets a value that is not an Integer in its range, or a
      #   +:string+ gets a value that is not valid UTF-8 and cannot be converted to it
      def write_value(type, value)
        case type
        when :byte then @buf << (checked_int(type, value) & 0xFF)
        when :i16, :i32, :i64 then write_zigzag(checked_int(type, value))
        when :double then @buf << [value].pack("E")
        when :binary then write_binary(value)
        when :string then write_binary(utf8(value))
        when Array then write_list(type[1], value)
        else write_struct(value)
        end
      end

      # Writes a list: a header with the size (inline when below 15) and element wire type,
      # then the elements. Booleans in lists are written as full bytes.
      #
      # @param elem_type [Symbol, Array, Class] declared element type
      # @param values [Array] the elements
      # @return [void]
      def write_list(elem_type, values)
        elem_wire = Thrift.wire_type_for(elem_type)
        if values.size < 15
          @buf << ((values.size << 4) | elem_wire)
        else
          @buf << (0xF0 | elem_wire)
          write_varint(values.size)
        end
        values.each do |v|
          if elem_type == :bool
            @buf << (v ? T_TRUE : T_FALSE)
          else
            write_value(elem_type, v)
          end
        end
      end

      private

      # @param type [Symbol] declared integer type, a key of INT_RANGES
      # @param value [Object] value to be written as +type+
      # @return [Integer] +value+
      # @raise [Error] when +value+ is not an Integer that +type+ can hold
      def checked_int(type, value)
        raise Error, "#{value.inspect} is not a valid #{type}" unless value.is_a?(Integer) && INT_RANGES.fetch(type).cover?(value)
        value
      end

      # Parquet strings are UTF-8. Binary Strings are taken to hold UTF-8 bytes, Strings in other
      # encodings are converted.
      #
      # @param s [String] value of a +:string+ field
      # @return [String] +s+, or a UTF-8 copy of it
      # @raise [Error] when +s+ is not valid UTF-8 and cannot be converted to it
      def utf8(s)
        return s if s.ascii_only? || (s.encoding == Encoding::UTF_8 && s.valid_encoding?)
        u = (s.encoding == Encoding::BINARY) ? s.dup.force_encoding(Encoding::UTF_8) : s.encode(Encoding::UTF_8)
        raise Error, "String in #{s.encoding} is not valid UTF-8" unless u.valid_encoding?
        u
      rescue EncodingError => e
        raise Error, "String in #{s.encoding} cannot be converted to UTF-8: #{e.message}"
      end
    end

    # A field declared on a Thrift::Struct subclass
    #
    # @!attribute [rw] id
    #   @return [Integer] Thrift field id
    # @!attribute [rw] name
    #   @return [Symbol] accessor name
    # @!attribute [rw] type
    #   @return [Symbol, Array, Class] declared type (see WIRE_TYPES)
    # @!attribute [rw] ivar
    #   @return [Symbol] instance variable holding the value (+:@name+)
    Field = ::Struct.new(:id, :name, :type, :ivar)

    # Base class for Thrift structs. Subclasses declare fields with
    #   field 1, :name, :i32
    class Struct
      class << self
        # @return [Array<Field>] declared fields, sorted by id, including the superclass's
        def fields
          @fields || ((superclass < Struct) ? superclass.fields : [])
        end

        # @return [Hash{Integer => Field}] declared fields by id, for decoding
        def fields_by_id
          @fields_by_id || ((superclass < Struct) ? superclass.fields_by_id : {})
        end

        # Declares a field and defines its accessor
        #
        # @param id [Integer] Thrift field id from parquet.thrift
        # @param name [Symbol] accessor name
        # @param type [Symbol, Array, Class] declared type: a WIRE_TYPES key, +[:list, elem]+
        #   or a Struct subclass
        # @return [void]
        def field(id, name, type)
          # Shareable, so that structs can be decoded in any Ractor
          @fields = Ractor.make_shareable((fields + [Field.new(id, name, type, :"@#{name}")]).sort_by(&:id))
          @fields_by_id = Ractor.make_shareable(@fields.to_h { |f| [f.id, f] })
          attr_accessor name
        end

        # Decodes an instance from +buf+ starting at +pos+
        #
        # @param buf [String] encoded data
        # @param pos [Integer] byte offset of the struct in +buf+
        # @return [Array(Struct, Integer)] the instance and the offset just past it
        # @raise [Error] on truncated or malformed data
        def decode(buf, pos = 0)
          reader = Reader.new(buf, pos)
          [reader.read_struct(self), reader.pos]
        end
      end

      # @param attrs [Hash{Symbol => Object}] initial field values, by accessor name
      # @option attrs [Object] :any_declared_field value for that field (nil leaves it unset); the
      #   keys are whatever fields the subclass declares
      # @raise [ArgumentError] for a name that is not a declared field
      def initialize(**attrs)
        attrs.each do |k, v|
          raise ArgumentError, "Unknown field #{k} for #{self.class}" unless respond_to?(:"#{k}=")
          public_send(:"#{k}=", v)
        end
      end

      # @return [String] the compact protocol encoding (binary)
      def encode
        w = Writer.new
        w.write_struct(self)
        w.buf
      end

      # Set fields as a Hash, with nested structs (also inside lists) converted too
      #
      # @return [Hash{Symbol => Object}] values by field name, nil fields left out
      def to_h
        self.class.fields.each_with_object({}) do |f, h|
          v = instance_variable_get(f.ivar)
          next if v.nil?
          h[f.name] = case v
          when Struct then v.to_h
          when Array then v.map { |e| e.is_a?(Struct) ? e.to_h : e }
          else v
          end
        end
      end

      # Structs are equal when they are of the same class and have the same field values
      #
      # @param other [Object] object to compare with
      # @return [Boolean] true when +other+ is an equal struct
      def ==(other)
        other.class == self.class && other.to_h == to_h
      end
      alias_method :eql?, :==

      # @return [Integer] hash agreeing with #==, so equal structs work as Hash keys and in +uniq+
      def hash
        [self.class, to_h].hash
      end

      # @return [String] short class name and the set fields
      def inspect
        "#<#{self.class.name.split("::").last} #{to_h.map { |k, v| "#{k}=#{v.inspect}" }.join(" ")}>"
      end
    end
  end
end

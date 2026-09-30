# frozen_string_literal: true

module Parakiet
  # Minimal Thrift Compact Protocol implementation, just enough for Parquet metadata.
  # Structs are described declaratively (see Parakiet::Thrift::Struct) so that
  # both the reader and the writer are driven by the same field tables.
  module Thrift
    class Error < StandardError; end

    # Compact protocol wire types
    T_STOP = 0
    T_TRUE = 1
    T_FALSE = 2
    T_BYTE = 3
    T_I16 = 4
    T_I32 = 5
    T_I64 = 6
    T_DOUBLE = 7
    T_BINARY = 8
    T_LIST = 9
    T_SET = 10
    T_MAP = 11
    T_STRUCT = 12

    # Declared field types used in struct definitions
    # :bool, :byte, :i16, :i32, :i64, :double, :binary, :string, [:list, elem], StructClass
    WIRE_TYPES = {
      bool: T_TRUE, byte: T_BYTE, i16: T_I16, i32: T_I32, i64: T_I64,
      double: T_DOUBLE, binary: T_BINARY, string: T_BINARY
    }.freeze

    def self.wire_type_for(type)
      case type
      when Symbol then WIRE_TYPES.fetch(type)
      when Array then T_LIST
      else T_STRUCT
      end
    end

    # Whether a value of wire type +wire+ can be read as declared +type+
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

    class Reader
      attr_reader :pos

      def initialize(buf, pos = 0)
        @buf = buf
        @pos = pos
      end

      def read_byte
        b = @buf.getbyte(@pos)
        raise Error, "Unexpected end of Thrift data at #{@pos}" unless b
        @pos += 1
        b
      end

      def read_varint
        result = 0
        shift = 0
        loop do
          b = read_byte
          result |= (b & 0x7F) << shift
          return result if b < 0x80
          shift += 7
          raise Error, "Varint too long" if shift > 70
        end
      end

      def read_zigzag
        n = read_varint
        (n >> 1) ^ -(n & 1)
      end

      def read_binary
        len = read_varint
        raise Error, "Binary length #{len} exceeds buffer" if @pos + len > @buf.bytesize
        s = @buf.byteslice(@pos, len)
        @pos += len
        s
      end

      def read_double
        v = @buf.byteslice(@pos, 8).unpack1("E")
        @pos += 8
        v
      end

      # Reads a struct of the given class, returning an instance.
      def read_struct(klass)
        obj = klass.new
        fields = klass.fields_by_id
        last_id = 0
        loop do
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

      def read_value(wire, type)
        case wire
        when T_TRUE then true
        when T_FALSE then false
        when T_BYTE
          b = read_byte
          b >= 0x80 ? b - 0x100 : b
        when T_I16, T_I32, T_I64 then read_zigzag
        when T_DOUBLE then read_double
        when T_BINARY
          s = read_binary
          type == :string ? s.force_encoding(Encoding::UTF_8) : s
        when T_LIST, T_SET then read_list(type)
        when T_STRUCT then read_struct(type)
        else
          raise Error, "Unsupported wire type #{wire}"
        end
      end

      def read_list(type)
        header = read_byte
        size = header >> 4
        size = read_varint if size == 15
        elem_wire = header & 0x0F
        elem_type = type[1]
        bool_elems = elem_wire == T_TRUE || elem_wire == T_FALSE
        unless size.zero? || (bool_elems && elem_type == :bool) || Thrift.compatible?(elem_wire, elem_type)
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

      def skip(wire)
        case wire
        when T_TRUE, T_FALSE then nil
        when T_BYTE then read_byte
        when T_I16, T_I32, T_I64 then read_varint
        when T_DOUBLE then @pos += 8
        when T_BINARY then read_binary
        when T_LIST, T_SET
          header = read_byte
          size = header >> 4
          size = read_varint if size == 15
          elem = header & 0x0F
          size.times { (elem == T_TRUE || elem == T_FALSE) ? read_byte : skip(elem) }
        when T_MAP
          size = read_varint
          unless size.zero?
            kv = read_byte
            size.times do
              skip(kv >> 4)
              skip(kv & 0x0F)
            end
          end
        when T_STRUCT
          loop do
            header = read_byte
            w = header & 0x0F
            break if w == T_STOP
            read_zigzag if (header >> 4).zero?
            skip(w)
          end
        else
          raise Error, "Cannot skip wire type #{wire}"
        end
      end
    end

    class Writer
      attr_reader :buf

      def initialize(buf = String.new(capacity: 1024, encoding: Encoding::BINARY))
        @buf = buf
      end

      def write_varint(n)
        raise Error, "Negative varint" if n.negative?
        while n >= 0x80
          @buf << ((n & 0x7F) | 0x80)
          n >>= 7
        end
        @buf << n
      end

      def write_zigzag(n)
        write_varint(n.negative? ? ((-n) << 1) - 1 : n << 1)
      end

      def write_binary(s)
        write_varint(s.bytesize)
        @buf << s.b
      end

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

      def write_value(type, value)
        case type
        when :byte then @buf << (value & 0xFF)
        when :i16, :i32, :i64 then write_zigzag(value)
        when :double then @buf << [value].pack("E")
        when :binary, :string then write_binary(value)
        when Array then write_list(type[1], value)
        else write_struct(value)
        end
      end

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
    end

    Field = ::Struct.new(:id, :name, :type, :ivar)

    # Base class for Thrift structs. Subclasses declare fields with
    #   field 1, :name, :i32
    class Struct
      class << self
        def fields
          @fields ||= []
        end

        def fields_by_id
          @fields_by_id ||= fields.to_h { |f| [f.id, f] }
        end

        def field(id, name, type)
          fields << Field.new(id, name, type, :"@#{name}")
          fields.sort_by!(&:id)
          @fields_by_id = nil
          attr_accessor name
        end

        def decode(buf, pos = 0)
          reader = Reader.new(buf, pos)
          [reader.read_struct(self), reader.pos]
        end
      end

      def initialize(**attrs)
        attrs.each do |k, v|
          raise ArgumentError, "Unknown field #{k} for #{self.class}" unless respond_to?(:"#{k}=")
          public_send(:"#{k}=", v)
        end
      end

      def encode
        w = Writer.new
        w.write_struct(self)
        w.buf
      end

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

      def ==(other)
        other.class == self.class && other.to_h == to_h
      end

      def inspect
        "#<#{self.class.name.split("::").last} #{to_h.map { |k, v| "#{k}=#{v.inspect}" }.join(" ")}>"
      end
    end
  end
end

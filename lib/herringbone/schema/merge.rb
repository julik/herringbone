# frozen_string_literal: true

module Herringbone
  class Schema
    # The union or intersection of two schemas, behind Schema#union and Schema#intersect. Fields
    # are matched by name at every level of nesting, and the type of a field both schemas have is
    # widened to one that holds the values of both without loss. Fields that do not fit are
    # collected rather than raised one by one, so a single IncompatibleSchema names them all.
    #
    # Leaf types are compared as Arrays like +[:int, 32, true]+ or +[:timestamp, :micros, false]+,
    # so the same type spelled with a logical type in one file and a converted type in another
    # still matches.
    class Merge
      # Shorthand for Format::Type
      T = Format::Type
      # Shorthand for Format::ConvertedType
      C = Format::ConvertedType

      # Converted integer annotations => [bit width, signed]
      INT_CONVERTED = {
        C::INT_8 => [8, true], C::INT_16 => [16, true], C::INT_32 => [32, true], C::INT_64 => [64, true],
        C::UINT_8 => [8, false], C::UINT_16 => [16, false], C::UINT_32 => [32, false], C::UINT_64 => [64, false]
      }.freeze

      # Converted annotations of time and timestamp columns => [kind, unit, adjusted to UTC]
      TIME_CONVERTED = {
        C::TIME_MILLIS => [:time, :millis, true], C::TIME_MICROS => [:time, :micros, true],
        C::TIMESTAMP_MILLIS => [:timestamp, :millis, true], C::TIMESTAMP_MICROS => [:timestamp, :micros, true]
      }.freeze

      # Converted annotations of UTF-8 byte arrays => the text kind
      TEXT_CONVERTED = {C::UTF8 => :string, C::ENUM => :enum, C::JSON => :json}.freeze

      # Time units from coarsest to finest
      TIME_UNITS = %i[millis micros nanos].freeze

      # Float width => bits of its significand, which is how wide an Integer it holds exactly
      FLOAT_SIGNIFICANDS = {16 => 11, 32 => 24, 64 => 53}.freeze

      # @param mode [Symbol] +:union+ or +:intersect+
      def initialize(mode)
        @mode = mode
        @conflicts = []
      end

      # @param mine [Schema] the receiver, whose field order comes first
      # @param theirs [Schema] the other schema
      # @return [Schema] a new schema sharing no nodes with either
      # @raise [IncompatibleSchema] listing every field that does not fit
      def call(mine, theirs)
        nodes = merge_members(mine.fields, theirs.fields, [])
        unless @conflicts.empty?
          raise IncompatibleSchema.new(@conflicts, operation: (@mode == :union) ? "unite" : "intersect")
        end
        Schema.new(Node.new(name: mine.root.name, repetition: :required, children: nodes))
      end

      private

      # Matches the members of two groups (or the top-level fields) by name: those of +mine+ in
      # order, then, for a union, those only +theirs+ has.
      #
      # @param mine [Array<Field>] fields of the receiver
      # @param theirs [Array<Field>] fields of the other schema
      # @param path [Array<String>] path of the enclosing group, empty at the top level
      # @return [Array<Node>] merged nodes; incomplete when a conflict was recorded
      def merge_members(mine, theirs, path)
        by_name = theirs.to_h { |f| [f.name, f] }
        names = mine.map(&:name)
        if @mode == :intersect && (names & by_name.keys).empty?
          conflict(path, "fields #{names.join(", ")}", "fields #{by_name.keys.join(", ")}", "no fields in common")
          return []
        end
        nodes = mine.map do |field|
          if (twin = by_name[field.name])
            merge(field, twin, path + [field.name])
          elsif @mode == :union
            nullable(field, path + [field.name], :left)
          end
        end
        if @mode == :union
          nodes += theirs.reject { |f| names.include?(f.name) }.map { |f| nullable(f, path + [f.name], :right) }
        end
        nodes.compact
      end

      # A field only one side of a union has: rows from the other side hold no value for it
      #
      # @param field [Field] the field only one schema has
      # @param path [Array<String>] path of the field
      # @param side [Symbol] +:left+ or +:right+, the schema that has it
      # @return [Node, nil] an optional copy of the field's node; nil for a conflict
      def nullable(field, path, side)
        unless field.node.repeated?
          return copy(field.node, repetition: :optional)
        end
        sides = ["repeated #{kind_label(field.element)}", "absent"]
        conflict(path, *((side == :left) ? sides : sides.reverse), "a repeated field cannot be null, so both schemas need it")
      end

      # @param a [Field] the field in the receiver
      # @param b [Field] the field of the same name in the other schema
      # @param path [Array<String>] path of the field
      # @return [Node, nil] the merged node; nil when a conflict was recorded
      def merge(a, b, path)
        an = a.node
        bn = b.node
        a_id = field_id_of(a)
        b_id = field_id_of(b)
        if a_id && b_id && a_id != b_id
          return conflict(path, "field_id #{a_id}", "field_id #{b_id}", "different field ids, so different columns")
        end
        if a.kind != b.kind
          return conflict(path, kind_label(a), kind_label(b), "a #{a.kind} and a #{b.kind} do not mix")
        end
        both_bare = a.kind == :list && an.repeated? && bn.repeated?
        repetition = if both_bare then :repeated
        elsif a.optional || b.optional then :optional
        else :required
        end
        field_id = a_id || b_id
        if shape(an) == shape(bn)
          enum_values = an.enum_values if an.enum_values == bn.enum_values
          return copy(an, repetition: repetition, field_id: field_id, enum_values: enum_values)
        end

        case a.kind
        when :leaf
          attrs = merge_leaf(an, bn, path) or return
          enum_values = an.enum_values if an.enum_values == bn.enum_values
          Node.new(name: an.name, repetition: repetition, field_id: field_id, enum_values: enum_values, **attrs)
        when :struct
          children = merge_members(a.children, b.children, path)
          Node.new(name: an.name, repetition: repetition, field_id: field_id, children: children) unless children.empty?
        when :list
          element = merge(a.element, b.element, path + ["element"]) or return
          if both_bare
            element.name = an.name
            element.repetition = :repeated
            element.field_id = field_id
            return element
          end
          element.name = "element"
          Node.new(name: an.name, repetition: repetition, field_id: field_id,
            children: [Node.new(name: "list", repetition: :repeated, children: [element])],
            logical_type: Format::LogicalType.new(list: Format::ListType.new), converted_type: C::LIST)
        when :map
          key = merge(a.key, b.key, path + ["key"])
          value = merge(a.value, b.value, path + ["value"])
          return unless key && value
          key.name = "key"
          key.repetition = :required
          value.name = "value"
          Node.new(name: an.name, repetition: repetition, field_id: field_id,
            children: [Node.new(name: "key_value", repetition: :repeated, children: [key, value])],
            logical_type: Format::LogicalType.new(map: Format::MapType.new), converted_type: C::MAP)
        end
      end

      # @param an [Node] leaf in the receiver
      # @param bn [Node] leaf of the same name in the other schema
      # @param path [Array<String>] path of the field
      # @return [Hash{Symbol => Object}, nil] physical attributes for Node.new; nil when a conflict
      #   was recorded
      def merge_leaf(an, bn, path)
        ta = leaf_type(an)
        tb = leaf_type(bn)
        return attributes_of(an) if ta == tb && ta.first == :other
        type, reason = (ta == tb) ? [ta] : widen(ta, tb)
        return conflict(path, label(ta), label(tb), reason) if reason
        attributes(type)
      end

      # @param field [Field] any field
      # @return [Integer, nil] the field id of its node, nil for the element of a bare repeated
      #   field, whose node (and field id) is that of the list
      def field_id_of(field)
        field.node.field_id unless field.node.repeated? && field.kind != :list
      end

      # @param ta [Array] leaf type of the receiver's field (see #leaf_type)
      # @param tb [Array] a different leaf type of the other schema's field
      # @return [Array(Array, nil), Array(nil, String)] the widened type, or why there is none
      def widen(ta, tb)
        case [ta.first, tb.first]
        when [:int, :int] then widen_ints(ta, tb)
        when [:float, :float] then [[:float, [ta[1], tb[1]].max]]
        when [:int, :float] then int_to_float(ta, tb)
        when [:float, :int] then int_to_float(tb, ta)
        when [:timestamp, :timestamp], [:time, :time]
          return [nil, "one is adjusted to UTC and the other is not"] if ta[2] != tb[2]
          [[ta[0], TIME_UNITS[[TIME_UNITS.index(ta[1]), TIME_UNITS.index(tb[1])].max], ta[2]]]
        when [:text, :text] then [[:text, :string]]
        when [:text, :binary], [:binary, :text] then [[:binary]]
        when [:decimal, :decimal] then [nil, "decimals need the same precision and scale"]
        else [nil, "no common type"]
        end
      end

      # @param ta [Array] an integer type
      # @param tb [Array] another integer type
      # @return [Array(Array, nil), Array(nil, String)] the narrowest integer holding both, or why
      #   there is none
      def widen_ints(ta, tb)
        _, a_bits, a_signed = ta
        _, b_bits, b_signed = tb
        return [[:int, [a_bits, b_bits].max, a_signed]] if a_signed == b_signed
        signed_bits, unsigned_bits = a_signed ? [a_bits, b_bits] : [b_bits, a_bits]
        return [nil, "uint64 does not fit any signed integer"] if unsigned_bits == 64
        [[:int, [signed_bits, unsigned_bits * 2].max, true]]
      end

      # @param int [Array] an integer type
      # @param float [Array] a float type
      # @return [Array(Array, nil), Array(nil, String)] the narrowest float at least as wide as
      #   +float+ that holds every value of +int+ exactly, or why there is none
      def int_to_float(int, float)
        _, bits, signed = int
        magnitude = signed ? bits - 1 : bits
        width = FLOAT_SIGNIFICANDS.find { |w, significand| w >= float[1] && significand >= magnitude }&.first
        return [nil, "#{label(int)} does not fit a double exactly"] unless width
        [[:float, width]]
      end

      # @param node [Node] a leaf
      # @return [Array] its type, independent of whether a logical or converted type spells it;
      #   +[:other, ...]+ for annotations nothing widens (INTERVAL, unknown logical types)
      def leaf_type(node)
        lt = node.logical_type
        case node.logical_kind
        when :integer then [:int, lt.integer.bit_width, lt.integer.is_signed]
        when :decimal then [:decimal, lt.decimal.precision, lt.decimal.scale]
        when :timestamp then [:timestamp, lt.timestamp.unit.to_sym, lt.timestamp.is_adjusted_to_utc]
        when :time then [:time, lt.time.unit.to_sym, lt.time.is_adjusted_to_utc]
        when :string, :enum, :json then [:text, node.logical_kind]
        when :float16 then [:float, 16]
        when :date, :uuid, :bson then [node.logical_kind]
        when nil
          # A logical type this version does not know decodes as an empty union
          lt ? [:other, shape(node), "an unknown logical type"] : converted_type(node)
        else [:other, shape(node), node.logical_kind.to_s]
        end
      end

      # @param node [Node] a leaf without a logical type
      # @return [Array] its type, see #leaf_type
      def converted_type(node)
        ct = node.converted_type
        if (int = INT_CONVERTED[ct]) then [:int, *int]
        elsif (time = TIME_CONVERTED[ct]) then time
        elsif (text = TEXT_CONVERTED[ct]) then [:text, text]
        elsif ct == C::DECIMAL then [:decimal, node.precision, node.scale || 0]
        elsif ct == C::DATE then [:date]
        elsif ct == C::BSON then [:bson]
        elsif ct then [:other, shape(node), C::NAMES[ct].to_s.downcase]
        else
          case node.type
          when T::BOOLEAN then [:boolean]
          when T::INT32 then [:int, 32, true]
          when T::INT64 then [:int, 64, true]
          when T::INT96 then [:int96]
          when T::FLOAT then [:float, 32]
          when T::DOUBLE then [:float, 64]
          when T::BYTE_ARRAY then [:binary]
          when T::FIXED_LEN_BYTE_ARRAY then [:fixed, node.type_length]
          end
        end
      end

      # @param type [Array] a leaf type, see #leaf_type
      # @return [Hash{Symbol => Object}] physical attributes for Node.new, as the Builder DSL
      #   declares that type
      def attributes(type)
        case type
        in [:int, 32, true] then Types.physical_attributes(:int32)
        in [:int, 64, true] then Types.physical_attributes(:int64)
        in [:int, bits, signed] then Types.int_type(bits, signed)
        in [:float, bits] then Types.physical_attributes({16 => :float16, 32 => :float, 64 => :double}.fetch(bits))
        in [:timestamp | :time => kind, unit, utc] then Types.physical_attributes(kind, unit: unit, utc: utc)
        in [:text, :enum] then Types.physical_attributes(:enum, parquet_enum: true)
        in [:text, kind] then Types.physical_attributes(kind)
        in [:decimal, precision, scale] then Types.physical_attributes(:decimal, precision: precision, scale: scale)
        in [:fixed, length] then Types.physical_attributes(:fixed, length: length)
        in [kind] then Types.physical_attributes(kind)
        end
      end

      # @param node [Node] a leaf
      # @return [Hash{Symbol => Object}] its physical attributes as they are
      def attributes_of(node)
        {type: node.type, type_length: node.type_length, converted_type: node.converted_type,
         logical_type: node.logical_type, scale: node.scale, precision: node.precision}
      end

      # @param type [Array] a leaf type, see #leaf_type
      # @return [String] e.g. "uint16", "timestamp(millis, UTC)", "decimal(10, 2)"
      def label(type)
        case type
        in [:int, bits, signed] then "#{"u" unless signed}int#{bits}"
        in [:float, bits] then {16 => "float16", 32 => "float", 64 => "double"}.fetch(bits)
        in [:timestamp | :time => kind, unit, utc] then "#{kind}(#{unit}, #{utc ? "UTC" : "local"})"
        in [:text, kind] then kind.to_s
        in [:decimal, precision, scale] then "decimal(#{precision}, #{scale})"
        in [:fixed, length] then "fixed(#{length})"
        in [:other, _, description] then description
        in [kind] then kind.to_s
        end
      end

      # @param field [Field] any field
      # @return [String] the leaf type's label, or "struct", "list" or "map"
      def kind_label(field)
        field.leaf? ? label(leaf_type(field.node)) : field.kind.to_s
      end

      # What two nodes must share to be merged as they are: Node#signature without the name,
      # repetition and field id of the node itself
      #
      # @param node [Node] any node
      # @return [Array]
      def shape(node)
        node.signature.values_at(2, 3, 4, 6)
      end

      # @param node [Node] node to copy, with its children
      # @param changes [Hash{Symbol => Object}] attributes to set on the copy (not on its children)
      # @option changes [Symbol] :repetition repetition of the copy
      # @option changes [Integer, nil] :field_id field id of the copy
      # @option changes [Array<String>, Hash, nil] :enum_values enum values of the copy
      # @return [Node] a copy sharing no nodes with the original
      def copy(node, **changes)
        attrs = {name: node.name, repetition: node.repetition, field_id: node.field_id,
                 enum_values: node.enum_values, children: node.children&.map { |c| copy(c) }}
        Node.new(**attrs.merge(attributes_of(node)).merge(changes))
      end

      # @param path [Array<String>] path of the field
      # @param left [String] the field in the receiver
      # @param right [String] the field in the other schema
      # @param reason [String] why they do not fit
      # @return [nil]
      def conflict(path, left, right, reason)
        @conflicts << IncompatibleSchema::Conflict.new(path.join("."), left, right, reason)
        nil
      end
    end
  end
end

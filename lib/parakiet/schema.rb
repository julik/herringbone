# frozen_string_literal: true

module Parakiet
  # A Parquet schema. Holds two views of the same tree:
  #
  # * the physical tree of Schema::Node (what is stored in the footer as SchemaElements),
  #   whose leaves are the column chunks (Schema::Column), and
  # * the logical tree of Schema::Field, which interprets LIST/MAP annotations and is
  #   what rows are assembled from (and shredded into) when reading and writing.
  class Schema
    REPETITIONS = {
      Format::Repetition::REQUIRED => :required,
      Format::Repetition::OPTIONAL => :optional,
      Format::Repetition::REPEATED => :repeated
    }.freeze

    # A node of the physical schema tree.
    class Node
      attr_accessor :name, :repetition, :type, :type_length, :converted_type, :logical_type,
        :scale, :precision, :field_id, :children, :parent

      def initialize(name:, repetition: :optional, type: nil, type_length: nil, converted_type: nil,
        logical_type: nil, scale: nil, precision: nil, field_id: nil, children: nil)
        @name = name.to_s
        @repetition = repetition
        @type = type
        @type_length = type_length
        @converted_type = converted_type
        @logical_type = logical_type
        @scale = scale
        @precision = precision
        @field_id = field_id
        @children = children
        @children&.each { |c| c.parent = self }
      end

      def group? = !@children.nil?
      def leaf? = @children.nil?
      def repeated? = @repetition == :repeated
      def optional? = @repetition == :optional

      def logical_kind
        @logical_type&.kind&.first
      end

      def list_annotated?
        logical_kind == :list || @converted_type == Format::ConvertedType::LIST
      end

      def map_annotated?
        logical_kind == :map || @converted_type == Format::ConvertedType::MAP ||
          @converted_type == Format::ConvertedType::MAP_KEY_VALUE
      end

      def path
        parent&.parent ? parent.path + [name] : [name]
      end

      def self.from_element(el)
        new(
          name: el.name,
          repetition: REPETITIONS.fetch(el.repetition_type || Format::Repetition::REQUIRED),
          type: el.num_children ? nil : el.type,
          type_length: el.type_length,
          converted_type: el.converted_type,
          logical_type: el.logical_type,
          scale: el.scale,
          precision: el.precision,
          field_id: el.field_id
        )
      end

      def to_element(root: false)
        Format::SchemaElement.new(
          name: name,
          repetition_type: root ? nil : REPETITIONS.key(repetition),
          type: type,
          type_length: type_length,
          num_children: group? ? children.size : nil,
          converted_type: converted_type,
          logical_type: logical_type,
          scale: scale,
          precision: precision,
          field_id: field_id
        )
      end
    end

    # A leaf column (one column chunk per row group)
    class Column
      attr_reader :index, :node, :path, :max_definition_level, :max_repetition_level

      def initialize(index, node, max_def, max_rep)
        @index = index
        @node = node
        @path = node.path
        @max_definition_level = max_def
        @max_repetition_level = max_rep
      end

      def type = @node.type
      def type_length = @node.type_length
      def dotted_path = @path.join(".")

      def converter
        @converter ||= Types.reader_for(@node)
      end

      def encoder
        @encoder ||= Types.writer_for(@node)
      end
    end

    # A node of the logical tree.
    #   kind:       :leaf, :struct, :list or :map
    #   optional:   whether this field itself may be null
    #   def_level:  definition level at which this field counts as present
    #   For :list and :map:
    #     rep_level:  repetition level of the repeated node
    #     item_def:   definition level at which the repeated node has at least one entry
    #     element:    element Field (lists); key/value Fields (maps, value may be nil)
    class Field
      attr_reader :kind, :name, :optional, :def_level, :rep_level, :item_def,
        :children, :element, :key, :value, :column, :leaves, :node

      def initialize(kind:, name:, optional:, def_level:, node:, rep_level: nil, item_def: nil,
        children: nil, element: nil, key: nil, value: nil, column: nil)
        @kind = kind
        @name = name
        @optional = optional
        @def_level = def_level
        @node = node
        @rep_level = rep_level
        @item_def = item_def
        @children = children
        @element = element
        @key = key
        @value = value
        @column = column
        @leaves = case kind
        when :leaf then [column]
        when :struct then children.flat_map(&:leaves)
        when :list then element.leaves
        when :map then key.leaves + (value ? value.leaves : [])
        end
      end

      def first_leaf = @leaves.first
      def leaf? = @kind == :leaf

      def children_by_name
        @children_by_name ||= @children.to_h { |c| [c.name, c] }
      end
    end

    attr_reader :root, :columns, :fields

    def self.from_elements(elements)
      raise FormatError, "Empty schema" if elements.empty?
      pos = 0
      build = lambda do
        el = elements[pos] or raise FormatError, "Schema is truncated"
        pos += 1
        node = Node.from_element(el)
        if el.num_children
          node.children = Array.new(el.num_children) { build.call }
          node.children.each { |c| c.parent = node }
        end
        node
      end
      root = build.call
      root.children ||= []
      new(root)
    end

    # Builds a schema with the DSL, see Schema::Builder
    def self.define(&block)
      builder = Builder.new
      builder.instance_eval(&block)
      new(Node.new(name: "schema", repetition: :required, children: builder.nodes))
    end

    def initialize(root)
      @root = root
      @columns = []
      collect_columns(root, 0, 0)
      @column_by_node = @columns.to_h { |c| [c.node, c] }
      @fields = root.children.map { |child| build_field(child, 0, 0) }
    end

    def to_elements
      out = []
      walk = lambda do |node, is_root|
        out << node.to_element(root: is_root)
        node.children&.each { |c| walk.call(c, false) }
      end
      walk.call(@root, true)
      out
    end

    def field(name)
      @fields.find { |f| f.name == name.to_s }
    end

    def column(path)
      path = path.split(".") if path.is_a?(String)
      @columns.find { |c| c.path == path }
    end

    def inspect
      lines = []
      walk = lambda do |node, depth|
        desc = if node.leaf?
          [Format::Type::NAMES[node.type], node.type_length && "(#{node.type_length})"].compact.join
        else
          "group"
        end
        ann = node.logical_type ? node.logical_type.kind.first.to_s.upcase : Format::ConvertedType::NAMES[node.converted_type]
        lines << "#{"  " * depth}#{node.repetition} #{desc} #{node.name}#{ann ? " (#{ann})" : ""}"
        node.children&.each { |c| walk.call(c, depth + 1) }
      end
      @root.children.each { |c| walk.call(c, 0) }
      "#<Parakiet::Schema\n#{lines.join("\n")}>"
    end
    alias_method :to_s, :inspect

    private

    def collect_columns(node, max_def, max_rep)
      node.children.each do |child|
        d = child.repetition == :required ? max_def : max_def + 1
        r = child.repeated? ? max_rep + 1 : max_rep
        if child.leaf?
          @columns << Column.new(@columns.size, child, d, r)
        else
          collect_columns(child, d, r)
        end
      end
    end

    def build_field(node, parent_def, parent_rep, as_element: false)
      if node.repeated? && !as_element
        # A repeated field outside of a LIST/MAP annotation is a list of required elements
        d = parent_def + 1
        r = parent_rep + 1
        element = build_field(node, d, r, as_element: true)
        return Field.new(kind: :list, name: node.name, optional: false, def_level: parent_def,
          rep_level: r, item_def: d, element: element, node: node)
      end

      optional = node.optional? && !as_element
      d = optional ? parent_def + 1 : parent_def

      if node.leaf?
        Field.new(kind: :leaf, name: node.name, optional: optional, def_level: d,
          column: @column_by_node.fetch(node), node: node)
      elsif node.list_annotated? && node.children.size == 1 && node.children[0].repeated?
        repeated = node.children[0]
        rd = d + 1
        rr = parent_rep + 1
        element = if list_element_is_repeated_node?(node, repeated)
          build_field(repeated, rd, rr, as_element: true)
        else
          build_field(repeated.children[0], rd, rr)
        end
        Field.new(kind: :list, name: node.name, optional: optional, def_level: d,
          rep_level: rr, item_def: rd, element: element, node: node)
      elsif node.map_annotated? && node.children.size == 1 && node.children[0].repeated? &&
          node.children[0].group? && node.children[0].children.size.between?(1, 2)
        kv = node.children[0]
        rd = d + 1
        rr = parent_rep + 1
        key = build_field(kv.children[0], rd, rr)
        # A map without values is read as a list of its keys, like Arrow does
        return Field.new(kind: :list, name: node.name, optional: optional, def_level: d,
          rep_level: rr, item_def: rd, element: key, node: node) unless kv.children[1]
        value = build_field(kv.children[1], rd, rr)
        Field.new(kind: :map, name: node.name, optional: optional, def_level: d,
          rep_level: rr, item_def: rd, key: key, value: value, node: node)
      else
        children = node.children.map { |c| build_field(c, d, parent_rep) }
        Field.new(kind: :struct, name: node.name, optional: optional, def_level: d,
          children: children, node: node)
      end
    end

    # Backward-compatibility rules from the Parquet LogicalTypes spec
    def list_element_is_repeated_node?(list_node, repeated)
      return true if repeated.leaf?
      return true if repeated.children.size > 1
      return true if repeated.name == "array" || repeated.name == "#{list_node.name}_tuple"
      false
    end

    # DSL for defining schemas:
    #
    #   Parakiet::Schema.define do
    #     int64 :id, null: false
    #     string :name
    #     list :tags, :string
    #     map :scores, :string, :double
    #     struct :address do
    #       string :city
    #     end
    #     decimal :price, precision: 12, scale: 2
    #     timestamp :created_at, unit: :micros
    #   end
    #
    # Fields are nullable unless null: false is given.
    class Builder
      attr_reader :nodes

      def initialize
        @nodes = []
      end

      PRIMITIVES = %i[
        boolean int8 int16 int32 int64 uint8 uint16 uint32 uint64 float double float16
        string binary json bson enum uuid date int96
      ].freeze

      PRIMITIVES.each do |t|
        define_method(t) { |name, **opts| column(name, t, **opts) }
      end

      def time(name, unit: :micros, utc: true, **opts) = column(name, :time, unit: unit, utc: utc, **opts)
      def timestamp(name, unit: :micros, utc: true, **opts) = column(name, :timestamp, unit: unit, utc: utc, **opts)
      def decimal(name, precision:, scale: 0, **opts) = column(name, :decimal, precision: precision, scale: scale, **opts)
      def fixed(name, length:, **opts) = column(name, :fixed, length: length, **opts)

      def struct(name, null: true, field_id: nil, &block)
        inner = Builder.new
        inner.instance_eval(&block)
        raise ArgumentError, "struct #{name} has no fields" if inner.nodes.empty?
        add Node.new(name: name, repetition: rep(null), children: inner.nodes, field_id: field_id)
      end

      # list :tags, :string
      # list :tags, :string, element_null: false
      # list :points, :struct do double :x; double :y; end
      # list :matrix do list :element, :double end   (block declares the element)
      def list(name, type = nil, null: true, element_null: true, field_id: nil, **type_opts, &block)
        element = element_node("element", type, element_null, type_opts, &block)
        repeated = Node.new(name: "list", repetition: :repeated, children: [element])
        add Node.new(name: name, repetition: rep(null), children: [repeated],
          logical_type: Format::LogicalType.new(list: Format::ListType.new),
          converted_type: Format::ConvertedType::LIST, field_id: field_id)
      end

      # map :scores, :string, :double
      # map :things, :string, :struct do int32 :a end
      def map(name, key_type, value_type = nil, null: true, value_null: true, field_id: nil, **type_opts, &block)
        key = element_node("key", key_type, false, {})
        value = element_node("value", value_type, value_null, type_opts, &block)
        kv = Node.new(name: "key_value", repetition: :repeated, children: [key, value])
        add Node.new(name: name, repetition: rep(null), children: [kv],
          logical_type: Format::LogicalType.new(map: Format::MapType.new),
          converted_type: Format::ConvertedType::MAP, field_id: field_id)
      end

      # Generic column declaration: column :name, :int32, null: false
      def column(name, type, null: true, field_id: nil, **opts)
        attrs = Types.physical_attributes(type, **opts)
        add Node.new(name: name, repetition: rep(null), field_id: field_id, **attrs)
      end

      private

      def add(node)
        raise ArgumentError, "Duplicate field #{node.name}" if @nodes.any? { |n| n.name == node.name }
        @nodes << node
        node
      end

      def rep(nullable) = nullable ? :optional : :required

      def element_node(name, type, nullable, type_opts, &block)
        if type.nil?
          raise ArgumentError, "Give an element type or a block declaring the element" unless block
          inner = Builder.new
          inner.instance_eval(&block)
          raise ArgumentError, "The element block must declare exactly one field" unless inner.nodes.size == 1
          node = inner.nodes.first
          node.name = name
          node
        elsif type.to_sym == :struct
          raise ArgumentError, "A struct element needs a block" unless block
          inner = Builder.new
          inner.instance_eval(&block)
          Node.new(name: name, repetition: rep(nullable), children: inner.nodes)
        else
          attrs = Types.physical_attributes(type.to_sym, **type_opts)
          Node.new(name: name, repetition: rep(nullable), **attrs)
        end
      end
    end
  end
end

# frozen_string_literal: true

module Herringbone
  # A Parquet schema. Holds two views of the same tree:
  #
  # * the physical tree of Schema::Node (what is stored in the footer as SchemaElements),
  #   whose leaves are the column chunks (Schema::Column), and
  # * the logical tree of Schema::Field, which interprets LIST/MAP annotations and is
  #   what rows are assembled from (and shredded into) when reading and writing.
  class Schema
    # Thrift FieldRepetitionType value => the Symbol used on Node#repetition
    REPETITIONS = {
      Format::Repetition::REQUIRED => :required,
      Format::Repetition::OPTIONAL => :optional,
      Format::Repetition::REPEATED => :repeated
    }.freeze

    # A node of the physical schema tree.
    class Node
      # Fields of the SchemaElement this node maps to (+type+ and +type_length+ are nil for groups);
      # +children+ is nil for leaves and +parent+ is nil for the root
      attr_accessor :name, :repetition, :type, :type_length, :converted_type, :logical_type,
        :scale, :precision, :field_id, :children, :parent
      # Allowed values of a string/enum column (writer-side validation only, not stored in the file)
      attr_accessor :enum_values

      # @param name [String, Symbol] field name, stored as a String
      # @param repetition [Symbol] +:required+, +:optional+ or +:repeated+
      # @param type [Integer, nil] physical type (Format::Type), nil for groups
      # @param type_length [Integer, nil] byte width of FIXED_LEN_BYTE_ARRAY columns
      # @param converted_type [Integer, nil] legacy annotation (Format::ConvertedType)
      # @param logical_type [Format::LogicalType, nil] logical type annotation
      # @param scale [Integer, nil] decimal scale
      # @param precision [Integer, nil] decimal precision
      # @param field_id [Integer, nil] optional field id, as used by Iceberg
      # @param children [Array<Node>, nil] child nodes of a group (their +parent+ is set to this node);
      #   nil for a leaf
      # @param enum_values [Array<String>, Hash{String => Object}, nil] see #enum_values
      def initialize(name:, repetition: :optional, type: nil, type_length: nil, converted_type: nil,
        logical_type: nil, scale: nil, precision: nil, field_id: nil, children: nil, enum_values: nil)
        @name = name.to_s
        @enum_values = enum_values
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

      # @return [Boolean] true for a group (a node with children, possibly none)
      def group? = !@children.nil?
      # @return [Boolean] true for a primitive column node
      def leaf? = @children.nil?
      # @return [Boolean] true when the repetition is +:repeated+
      def repeated? = @repetition == :repeated
      # @return [Boolean] true when the repetition is +:optional+
      def optional? = @repetition == :optional

      # @return [Symbol, nil] the LogicalType union member that is set (+:string+, +:list+,
      #   +:decimal+...), or nil without a logical type
      def logical_kind
        @logical_type&.kind&.first
      end

      # @return [Boolean] whether the node carries a LIST logical or converted type
      def list_annotated?
        logical_kind == :list || @converted_type == Format::ConvertedType::LIST
      end

      # @return [Boolean] whether the node carries a MAP logical type, or a MAP / MAP_KEY_VALUE
      #   converted type
      def map_annotated?
        logical_kind == :map || @converted_type == Format::ConvertedType::MAP ||
          @converted_type == Format::ConvertedType::MAP_KEY_VALUE
      end

      # @return [Array<String>] names from the top-level field down to this node, without the
      #   root's name (the +path_in_schema+ of a column)
      def path
        parent&.parent ? parent.path + [name] : [name]
      end

      # Builds a node without children from a footer SchemaElement; Schema.from_elements attaches them.
      #
      # @param el [Format::SchemaElement] element read from the footer
      # @return [Node] node with +children+ nil; a missing repetition is taken as required
      # @raise [KeyError] when the repetition type is not a known value
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

      # @param root [Boolean] true for the schema root, which is written without a repetition type
      # @return [Format::SchemaElement] element for the footer's flattened schema list
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
      # Position among the leaf columns (the column chunk order in a row group), the leaf Node,
      # its path (Node#path), and the maximum definition / repetition levels of its values
      attr_reader :index, :node, :path, :max_definition_level, :max_repetition_level

      # @param index [Integer] position among the schema's leaf columns
      # @param node [Node] leaf node of the physical tree
      # @param max_def [Integer] maximum definition level (number of non-required nodes on the path)
      # @param max_rep [Integer] maximum repetition level (number of repeated nodes on the path)
      def initialize(index, node, max_def, max_rep)
        @index = index
        @node = node
        @path = node.path
        @max_definition_level = max_def
        @max_repetition_level = max_rep
      end

      # @return [Integer] physical type (Format::Type)
      def type = @node.type
      # @return [Integer, nil] byte width for FIXED_LEN_BYTE_ARRAY columns
      def type_length = @node.type_length
      # @return [String] path joined with dots, as used for column names in options
      def dotted_path = @path.join(".")

      # Types.reader_for of the node. Not memoized: a Schema holding Procs could not be made
      # Ractor-shareable.
      #
      # @return [Proc, Method, nil] converts a physical value into its Ruby value, or nil when the physical
      #   value is used as-is
      def converter = Types.reader_for(@node)

      # Types.writer_for of the node. Not memoized, like #converter.
      #
      # @return [Proc, Method] converts a Ruby value into the physical value to store, raising
      #   ArgumentError / TypeError / RangeError for values that do not fit
      def encoder = Types.writer_for(@node)
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
      # As described for the class; +children+ are the Fields of a :struct, +column+ is the Column of a :leaf,
      # +leaves+ are all Columns under this field, and +node+ is the physical Node it was built from
      attr_reader :kind, :name, :optional, :def_level, :rep_level, :item_def,
        :children, :element, :key, :value, :column, :leaves, :node

      # @param kind [Symbol] +:leaf+, +:struct+, +:list+ or +:map+
      # @param name [String] field name
      # @param optional [Boolean] whether this field itself may be null
      # @param def_level [Integer] definition level at which this field counts as present
      # @param node [Node] physical node the field was built from
      # @param rep_level [Integer, nil] repetition level of the repeated node (lists and maps)
      # @param item_def [Integer, nil] definition level at which a list or map has an entry
      # @param children [Array<Field>, nil] fields of a struct
      # @param element [Field, nil] element of a list
      # @param key [Field, nil] key of a map
      # @param value [Field, nil] value of a map
      # @param column [Column, nil] column of a leaf
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

      # @return [Column] first leaf column under this field
      def first_leaf = @leaves.first
      # @return [Boolean] true for a primitive (+:leaf+) field
      def leaf? = @kind == :leaf

      # Lookup of a struct's children; only valid for +:struct+ fields.
      #
      # @return [Hash{String => Field}] child fields by name
      def children_by_name = @children.to_h { |c| [c.name, c] }
    end

    # The root Node, the leaf Columns in file order, and the top-level Fields of the logical tree
    attr_reader :root, :columns, :fields

    # Rebuilds the tree from the depth-first list of SchemaElements stored in the footer.
    #
    # @param elements [Array<Format::SchemaElement>] footer schema, root first
    # @return [Schema]
    # @raise [FormatError] when the list is empty or ends before all declared children are read
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
    #
    #   Herringbone::Schema.define do |s|
    #     s.int64 :id, null: false
    #     s.string :name
    #   end
    #
    # @yield [s] declares the top-level fields
    # @yieldparam s [Builder] the builder to declare fields on
    # @yieldreturn [void]
    # @return [Schema]
    # @raise [ArgumentError] when no field is declared, a declaration is invalid, or the block takes
    #   no parameter
    def self.define(&block)
      builder = Builder.build("Herringbone::Schema.define { |s| s.int64 :id }", &block)
      raise ArgumentError, "A schema needs at least one field" if builder.nodes.empty?
      new(Node.new(name: "schema", repetition: :required, children: builder.nodes))
    end

    # Number of leading rows Schema.infer looks at
    INFER_SAMPLE = 1000

    # Infers a schema from the first 1000 rows (Hashes, or objects responding to #attributes or
    # #to_h). All fields are nullable. Integer -> int64, Integer mixed with Float -> double,
    # String/Symbol -> string (binary if not valid UTF-8), true/false -> boolean,
    # Time/DateTime -> timestamp(micros), Date -> date, BigDecimal -> decimal(38, max scale seen),
    # Hash -> struct, Array -> list. Columns that are nil in every sampled row become strings.
    # Fields declared in the block (Builder DSL) replace the inferred ones of the same name:
    #   Schema.infer(rows) { |s| s.json :payload }
    #
    # @param rows [Enumerable<Hash, Object>] rows to sample; only the first INFER_SAMPLE are read
    # @yield [s] optional, declares fields that replace inferred ones (or are added after them)
    # @yieldparam s [Builder] the builder to declare fields on
    # @yieldreturn [void]
    # @return [Schema]
    # @raise [ArgumentError] when there are no rows, a row is not Hash-like, a column mixes values
    #   that map to no single Parquet type, or the block takes no parameter
    def self.infer(rows, &block)
      overrides = Builder.build("Herringbone::Schema.infer(rows) { |s| s.json :payload }", &block)
      sample_rows = rows.first(INFER_SAMPLE).map { |r| Inference.row_hash(r) }
      raise ArgumentError, "Cannot infer a schema from zero rows" if sample_rows.empty?
      declared = overrides.nodes.to_h { |n| [n.name, n] }
      names = sample_rows.flat_map { |r| r.keys.map(&:to_s) }.uniq
      nodes = names.map do |name|
        declared.delete(name) || Inference.node_for(name, sample_rows.map { |r| r.fetch(name) { r[name.to_sym] } })
      end
      new(Node.new(name: "schema", repetition: :required, children: nodes + declared.values))
    end

    # Type inference behind Schema.infer
    module Inference
      module_function

      # @param row [Hash, #attributes, #to_h] sampled row
      # @return [Hash] the row as a Hash keyed by field name (String or Symbol keys)
      # @raise [ArgumentError] when the row is positional (an Array), or neither a Hash nor converts
      #   to one
      def row_hash(row)
        return row if row.is_a?(Hash)
        raise ArgumentError, "Cannot infer a schema from Array rows (values in schema order); pass a schema" if row.is_a?(Array)
        return row.attributes if row.respond_to?(:attributes)
        return row.to_h if row.respond_to?(:to_h)
        raise ArgumentError, "Cannot infer a schema from a #{row.class}"
      end

      # Hashes become groups, Arrays become 3-level LIST groups, other values a primitive column;
      # nil values are ignored and an all-nil column becomes a string.
      #
      # @param name [String] field name
      # @param values [Array<Object>] the field's values across the sampled rows
      # @return [Node] optional node for the field
      # @raise [ArgumentError] when the values have no common Parquet type
      def node_for(name, values)
        present = values.compact
        return Node.new(name: name, **Types.physical_attributes(:string)) if present.empty?
        if present.all? { |v| v.is_a?(Hash) }
          keys = present.flat_map { |h| h.keys.map(&:to_s) }.uniq
          children = keys.map { |k| node_for(k, present.map { |h| h.fetch(k) { h[k.to_sym] } }) }
          Node.new(name: name, children: children)
        elsif present.all? { |v| v.is_a?(Array) }
          element = node_for("element", present.flatten(1))
          Node.new(name: name, children: [Node.new(name: "list", repetition: :repeated, children: [element])],
            logical_type: Format::LogicalType.new(list: Format::ListType.new), converted_type: Format::ConvertedType::LIST)
        else
          type, opts = scalar_type(name, present)
          Node.new(name: name, **Types.physical_attributes(type, **(opts || {})))
        end
      end

      # @param name [String] field name, for the error message
      # @param values [Array<Object>] non-nil values of the field
      # @return [Array(Symbol), Array(Symbol, Hash{Symbol => Object})] DSL type, plus its options
      #   for types that take some (decimal, timestamp)
      # @raise [ArgumentError] when the values have no common Parquet type
      def scalar_type(name, values)
        all = ->(*classes) { values.all? { |v| classes.any? { |c| v.is_a?(c) } } }
        if all.call(Integer)
          [:int64]
        elsif all.call(true.class, false.class)
          [:boolean]
        elsif all.call(Integer, BigDecimal)
          scale = values.map { |v| v.is_a?(BigDecimal) ? v.to_s("F").split(".")[1].to_s.sub(/0+\z/, "").size : 0 }.max
          [:decimal, {precision: 38, scale: scale}]
        elsif all.call(Numeric)
          [:double]
        elsif all.call(String)
          (values.all? { |v| v.encoding != Encoding::BINARY && v.valid_encoding? }) ? [:string] : [:binary]
        elsif all.call(String, Symbol)
          [:string]
        elsif all.call(Time, DateTime)
          [:timestamp, {unit: :micros}]
        elsif all.call(Date)
          [:date]
        else
          classes = values.map(&:class).uniq
          raise ArgumentError, "Cannot infer a Parquet type for #{name} from #{classes.map(&:name).join(", ")}; " \
            "declare it in a block: Schema.infer(rows) { |s| s.string :#{name} }"
        end
      end
    end

    # @param root [Node] root group of the physical tree, with +children+ set
    def initialize(root)
      @root = root
      @columns = []
      collect_columns(root, 0, 0)
      @column_by_node = @columns.to_h { |c| [c.node, c] }
      @fields = root.children.map { |child| build_field(child, 0, 0) }
    end

    # @return [Array<Format::SchemaElement>] the tree flattened depth-first, root first, as stored
    #   in the footer
    def to_elements
      out = []
      walk = lambda do |node, is_root|
        out << node.to_element(root: is_root)
        node.children&.each { |c| walk.call(c, false) }
      end
      walk.call(@root, true)
      out
    end

    # @param name [String, Symbol] top-level field name
    # @return [Field, nil] the top-level field, or nil when there is none by that name
    def field(name)
      @fields.find { |f| f.name == name.to_s }
    end

    # @param path [String, Array<String>] dotted path or path components of a leaf column
    # @return [Column, nil] the leaf column, or nil when there is none at that path
    def column(path)
      path = path.split(".") if path.is_a?(String)
      @columns.find { |c| c.path == path }
    end

    # @return [String] one line per node, indented by depth: repetition, physical type, name and
    #   annotation
    def inspect
      lines = []
      walk = lambda do |node, depth|
        desc = if node.leaf?
          [Format::Type::NAMES[node.type], node.type_length && "(#{node.type_length})"].compact.join
        else
          "group"
        end
        # A logical type this version does not know decodes as an empty union
        kind = node.logical_type&.kind
        ann = if kind then kind.first.to_s.upcase
        elsif node.logical_type then "UNKNOWN LOGICAL TYPE"
        else Format::ConvertedType::NAMES[node.converted_type]
        end
        lines << "#{"  " * depth}#{node.repetition} #{desc} #{node.name}#{" (#{ann})" if ann}"
        node.children&.each { |c| walk.call(c, depth + 1) }
      end
      @root.children.each { |c| walk.call(c, 0) }
      "#<Herringbone::Schema\n#{lines.join("\n")}>"
    end
    alias_method :to_s, :inspect

    private

    # Appends a Column for every leaf under +node+, depth-first. A non-required node adds one
    # definition level and a repeated node one repetition level.
    #
    # @param node [Node] group whose descendants are walked
    # @param max_def [Integer] definition level of +node+ itself
    # @param max_rep [Integer] repetition level of +node+ itself
    # @return [void]
    def collect_columns(node, max_def, max_rep)
      node.children.each do |child|
        d = (child.repetition == :required) ? max_def : max_def + 1
        r = child.repeated? ? max_rep + 1 : max_rep
        if child.leaf?
          @columns << Column.new(@columns.size, child, d, r)
        else
          collect_columns(child, d, r)
        end
      end
    end

    # Builds the logical Field for +node+, recognizing LIST and MAP annotations (including the
    # legacy 2-level forms) and bare repeated fields.
    #
    # @param node [Node] physical node to interpret
    # @param parent_def [Integer] definition level of the enclosing field
    # @param parent_rep [Integer] repetition level of the enclosing field
    # @param as_element [Boolean] true when +node+ is itself the repeated node of a list, so its
    #   repetition is already accounted for and it is not optional
    # @return [Field]
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
        unless kv.children[1]
          return Field.new(kind: :list, name: node.name, optional: optional, def_level: d,
            rep_level: rr, item_def: rd, element: key, node: node)
        end
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
    #
    # @param list_node [Node] LIST-annotated group
    # @param repeated [Node] its only (repeated) child
    # @return [Boolean] true when +repeated+ is the element itself (2-level list), false when its
    #   single child is the element (standard 3-level list)
    def list_element_is_repeated_node?(list_node, repeated)
      return true if repeated.leaf?
      return true if repeated.children.size > 1
      return true if repeated.name == "array" || repeated.name == "#{list_node.name}_tuple"
      false
    end

    # DSL for defining schemas:
    #
    #   Herringbone::Schema.define do |s|
    #     s.int64 :id, null: false
    #     s.string :name
    #     s.list :tags, :string
    #     s.map :scores, :string, :double
    #     s.struct :address do |address|
    #       address.string :city
    #     end
    #     s.decimal :price, precision: 12, scale: 2
    #     s.timestamp :created_at, unit: :micros
    #   end
    #
    # Fields are nullable unless null: false is given. The blocks of #struct, #list and #map get
    # a Builder of their own.
    class Builder
      # @return [Array<Node>] fields declared so far, in declaration order
      attr_reader :nodes

      # Yields a new Builder to the block.
      #
      # @param usage [String] how the entry point is called with a block, for the error message
      # @yield [s] declares fields
      # @yieldparam s [Builder] the new builder
      # @yieldreturn [void]
      # @return [Builder] the builder, with no fields when there is no block
      # @raise [ArgumentError] when the block takes no parameter
      def self.build(usage, &block)
        check_block!(block, usage)
        builder = new
        block&.call(builder)
        builder
      end

      # A block without a parameter was most likely written for the +instance_eval+ DSL of
      # earlier versions, and would fail on its first declaration with a NoMethodError
      #
      # @param block [Proc, nil] the block given to the entry point
      # @param usage [String] how the entry point is called with a block, for the error message
      # @return [void]
      # @raise [ArgumentError] when the block takes no parameter
      def self.check_block!(block, usage)
        return if block.nil? || !block.parameters.empty?
        raise ArgumentError, "The block receives the schema builder as a parameter: #{usage}"
      end

      # Starts with no fields
      def initialize
        @nodes = []
      end

      # Types that need no options; each gets a DSL method taking a name and the options of #column,
      # e.g. +s.int64 :id, null: false+
      PRIMITIVES = %i[
        boolean int8 int16 int32 int64 uint8 uint16 uint32 uint64 float double float16
        string binary json bson uuid date int96
      ].freeze

      PRIMITIVES.each do |t|
        define_method(t) { |name, **opts| column(name, t, **opts) }
      end

      # A TIME column; millis are stored as INT32, micros and nanos as INT64.
      #
      # @param name [String, Symbol] field name
      # @param unit [Symbol] +:millis+, +:micros+ or +:nanos+
      # @param utc [Boolean] the isAdjustedToUTC flag of the logical type
      # @param opts [Hash{Symbol => Object}] options of #column
      # @option opts [Boolean] :null (true) whether the field is nullable
      # @option opts [Integer, nil] :field_id (nil) field id to store in the schema
      # @return [Node] the added node
      # @raise [ArgumentError] for an unknown unit or a duplicate name
      def time(name, unit: :micros, utc: true, **opts) = column(name, :time, unit: unit, utc: utc, **opts)
      # A TIMESTAMP column, stored as INT64.
      #
      # @param name [String, Symbol] field name
      # @param unit [Symbol] +:millis+, +:micros+ or +:nanos+
      # @param utc [Boolean] the isAdjustedToUTC flag: true for instants, false for local date-times
      # @param opts [Hash{Symbol => Object}] options of #column
      # @option opts [Boolean] :null (true) whether the field is nullable
      # @option opts [Integer, nil] :field_id (nil) field id to store in the schema
      # @return [Node] the added node
      # @raise [ArgumentError] for an unknown unit or a duplicate name
      def timestamp(name, unit: :micros, utc: true, **opts) = column(name, :timestamp, unit: unit, utc: utc, **opts)
      # A DECIMAL column. Up to 9 digits are stored as INT32, up to 18 as INT64, more as a
      # FIXED_LEN_BYTE_ARRAY of the minimal width, unless +physical:+ says otherwise.
      #
      # @param name [String, Symbol] field name
      # @param precision [Integer] total number of digits
      # @param scale [Integer] digits after the decimal point, between 0 and +precision+
      # @param opts [Hash{Symbol => Object}] options of #column
      # @option opts [Symbol] :physical storage: +:int32+, +:int64+, +:binary+ or +:fixed+
      # @option opts [Boolean] :null (true) whether the field is nullable
      # @option opts [Integer, nil] :field_id (nil) field id to store in the schema
      # @return [Node] the added node
      # @raise [ArgumentError] for an invalid precision or scale, or a duplicate name
      def decimal(name, precision:, scale: 0, **opts) = column(name, :decimal, precision: precision, scale: scale, **opts)
      # A FIXED_LEN_BYTE_ARRAY column without annotation.
      #
      # @param name [String, Symbol] field name
      # @param length [Integer] byte width of every value
      # @param opts [Hash{Symbol => Object}] options of #column
      # @option opts [Boolean] :null (true) whether the field is nullable
      # @option opts [Integer, nil] :field_id (nil) field id to store in the schema
      # @return [Node] the added node
      # @raise [ArgumentError] for a duplicate name
      def fixed(name, length:, **opts) = column(name, :fixed, length: length, **opts)

      # A group of named fields.
      #
      # @param name [String, Symbol] field name
      # @param null [Boolean] whether the struct as a whole may be null
      # @param field_id [Integer, nil] field id to store in the schema
      # @yield [struct] declares the struct's fields
      # @yieldparam struct [Builder] a new builder for the struct's fields
      # @yieldreturn [void]
      # @return [Node] the added group node
      # @raise [ArgumentError] when the block is missing, takes no parameter or declares no fields,
      #   or for a duplicate name
      def struct(name, null: true, field_id: nil, &block)
        children = struct_fields(name, usage(name, "struct :#{name}", "string :city"), &block)
        add Node.new(name: name, repetition: rep(null), children: children, field_id: field_id)
      end

      #   s.list :tags, :string
      #   s.list :tags, :string, element_null: false
      #   s.list :points, :struct do |points| points.double :x; points.double :y end
      #   s.list :matrix do |matrix| matrix.list :element, :double end # block declares the element
      #
      # Written as the standard 3-level LIST: an optional (or required) group holding a repeated
      # group "list" whose single child is "element".
      #
      # @param name [String, Symbol] field name
      # @param type [Symbol, String, nil] element type (any #column type, or +:struct+ with a block);
      #   nil when the block declares the element
      # @param null [Boolean] whether the list itself may be null
      # @param element_null [Boolean] whether elements may be null; ignored when the block declares
      #   the element, which then keeps its own +null:+
      # @param field_id [Integer, nil] field id to store in the schema
      # @param type_opts [Hash{Symbol => Object}] options of the element type (+precision:+, +unit:+...)
      # @option type_opts [Integer] :precision decimal precision
      # @option type_opts [Integer] :scale decimal scale
      # @option type_opts [Symbol] :unit time or timestamp unit
      # @option type_opts [Boolean] :utc time or timestamp UTC adjustment
      # @option type_opts [Integer] :length FIXED_LEN_BYTE_ARRAY width
      # @yield [list] declares the struct's fields for a +:struct+ element, or exactly one field
      #   (renamed to "element") when +type+ is nil
      # @yieldparam list [Builder] a new builder for the element
      # @yieldreturn [void]
      # @return [Node] the added LIST group node
      # @raise [ArgumentError] when neither a type nor a block is given, the block takes no parameter
      #   or declares the wrong number of fields, or for a duplicate name
      def list(name, type = nil, null: true, element_null: true, field_id: nil, **type_opts, &block)
        example = if type
          usage(name, "list :#{name}, :#{type}", "double :x")
        else
          usage(name, "list :#{name}", "list :element, :double")
        end
        element = element_node("element", type, element_null, type_opts, example, &block)
        repeated = Node.new(name: "list", repetition: :repeated, children: [element])
        add Node.new(name: name, repetition: rep(null), children: [repeated],
          logical_type: Format::LogicalType.new(list: Format::ListType.new),
          converted_type: Format::ConvertedType::LIST, field_id: field_id)
      end

      #   s.map :scores, :string, :double
      #   s.map :things, :string, :struct do |things| things.int32 :a end
      #
      # Written as the standard MAP: a group holding a repeated group "key_value" with a required
      # "key" and a "value". Keys are never null.
      #
      # @param name [String, Symbol] field name
      # @param key_type [Symbol, String] key type (a primitive #column type)
      # @param value_type [Symbol, String, nil] value type (any #column type, or +:struct+ with a
      #   block); nil when the block declares the value
      # @param null [Boolean] whether the map itself may be null
      # @param value_null [Boolean] whether values may be null; ignored when the block declares the value
      # @param field_id [Integer, nil] field id to store in the schema
      # @param type_opts [Hash{Symbol => Object}] options of the value type (+precision:+, +unit:+...)
      # @option type_opts [Integer] :precision decimal precision
      # @option type_opts [Integer] :scale decimal scale
      # @option type_opts [Symbol] :unit time or timestamp unit
      # @option type_opts [Boolean] :utc time or timestamp UTC adjustment
      # @option type_opts [Integer] :length FIXED_LEN_BYTE_ARRAY width
      # @yield [map] declares the struct's fields for a +:struct+ value, or exactly one field
      #   (renamed to "value") when +value_type+ is nil
      # @yieldparam map [Builder] a new builder for the value
      # @yieldreturn [void]
      # @return [Node] the added MAP group node
      # @raise [ArgumentError] for an invalid key or value declaration, a block that takes no
      #   parameter, or a duplicate name
      def map(name, key_type, value_type = nil, null: true, value_null: true, field_id: nil, **type_opts, &block)
        head = ["map :#{name}", ":#{key_type}", (":#{value_type}" if value_type)].compact.join(", ")
        key = element_node("key", key_type, false, {}, nil)
        value = element_node("value", value_type, value_null, type_opts, usage(name, head, "int32 :a"), &block)
        kv = Node.new(name: "key_value", repetition: :repeated, children: [key, value])
        add Node.new(name: name, repetition: rep(null), children: [kv],
          logical_type: Format::LogicalType.new(map: Format::MapType.new),
          converted_type: Format::ConvertedType::MAP, field_id: field_id)
      end

      # Generic column declaration: s.column :name, :int32, null: false
      #
      # @param name [String, Symbol] field name
      # @param type [Symbol, String] DSL type: one of PRIMITIVES, or +:time+, +:timestamp+,
      #   +:decimal+, +:fixed+, +:enum+ with their options
      # @param null [Boolean] whether the field is nullable (optional rather than required)
      # @param field_id [Integer, nil] field id to store in the schema
      # @param opts [Hash{Symbol => Object}] type options
      # @option opts [Integer] :precision decimal precision (required for +:decimal+)
      # @option opts [Integer] :scale (0) decimal scale
      # @option opts [Symbol] :physical decimal storage: +:int32+, +:int64+, +:binary+ or +:fixed+
      # @option opts [Symbol] :unit (:micros) time or timestamp unit
      # @option opts [Boolean] :utc (true) time or timestamp UTC adjustment
      # @option opts [Integer] :length FIXED_LEN_BYTE_ARRAY width (required for +:fixed+)
      # @option opts [Array<String>, Hash] :values allowed values, see #enum
      # @option opts [Boolean] :parquet_enum (false) ENUM instead of STRING annotation, see #enum
      # @return [Node] the added leaf node
      # @raise [ArgumentError] for an unknown type, invalid type options, or a duplicate name
      def column(name, type, null: true, field_id: nil, **opts)
        add leaf_node(name, type, rep(null), opts).tap { |n| n.field_id = field_id }
      end

      # A string column. With parquet_enum: true it carries the ENUM annotation instead of STRING
      # (note that pyarrow and pandas then read it as binary). values: restricts what can be
      # written: an Array of labels, or a Hash like Rails' `Order.statuses` (label => stored value),
      # in which case both labels and stored values are accepted and the label is written.
      #
      # @param name [String, Symbol] field name
      # @param values [Array<String, Symbol>, Hash{String, Symbol => Object}, nil] allowed labels,
      #   or label => stored value; nil allows any string
      # @param parquet_enum [Boolean] annotate as ENUM instead of STRING
      # @param opts [Hash{Symbol => Object}] options of #column
      # @option opts [Boolean] :null (true) whether the field is nullable
      # @option opts [Integer, nil] :field_id (nil) field id to store in the schema
      # @return [Node] the added leaf node
      # @raise [ArgumentError] for a duplicate name
      def enum(name, values: nil, parquet_enum: false, **opts)
        column(name, :enum, values: values, parquet_enum: parquet_enum, **opts)
      end

      private

      # @param node [Node] node to append to #nodes
      # @return [Node] +node+
      # @raise [ArgumentError] when a field of the same name was already declared
      def add(node)
        raise ArgumentError, "Duplicate field #{node.name}" if @nodes.any? { |n| n.name == node.name }
        @nodes << node
        node
      end

      # @param nullable [Boolean] whether the field may be null
      # @return [Symbol] +:optional+ or +:required+
      def rep(nullable) = nullable ? :optional : :required

      # Builds the element of a list, or the key or value of a map.
      #
      # @param name [String] node name ("element", "key" or "value")
      # @param type [Symbol, String, nil] DSL type, +:struct+, or nil to take the field the block declares
      # @param nullable [Boolean] whether the node may be null (not applied to a block-declared field)
      # @param type_opts [Hash{Symbol => Object}] type options passed to Types.physical_attributes
      # @param example [String, nil] the declaration called with a block, for the error message
      # @yield [inner] declares the element, or the fields of a +:struct+
      # @yieldparam inner [Builder] a new builder
      # @yieldreturn [void]
      # @return [Node] the element node, not added to #nodes
      # @raise [ArgumentError] when the block is missing or takes no parameter, declares the wrong
      #   number of fields, or declares no fields for a +:struct+
      def element_node(name, type, nullable, type_opts, example, &block)
        if type.nil?
          raise ArgumentError, "Give an element type or a block declaring the element" unless block
          inner = Builder.build(example, &block)
          raise ArgumentError, "The element block must declare exactly one field" unless inner.nodes.size == 1
          node = inner.nodes.first
          node.name = name
          node
        elsif type.to_sym == :struct
          Node.new(name: name, repetition: rep(nullable), children: struct_fields(name, example, &block))
        else
          leaf_node(name, type, rep(nullable), type_opts)
        end
      end

      # Yields a new Builder for a struct's fields; Parquet groups need at least one child.
      #
      # @param name [String, Symbol] struct name, for the error message
      # @param example [String] the declaration called with a block, for the error message
      # @yield [inner] declares the struct's fields
      # @yieldparam inner [Builder] a new builder
      # @yieldreturn [void]
      # @return [Array<Node>] the declared fields
      # @raise [ArgumentError] when the block is missing, takes no parameter or declares no fields
      def struct_fields(name, example, &block)
        raise ArgumentError, "struct #{name} needs a block declaring its fields" unless block
        inner = Builder.build(example, &block)
        raise ArgumentError, "struct #{name} has no fields" if inner.nodes.empty?
        inner.nodes
      end

      # @param name [String, Symbol] field name, which names the block parameter when it can
      # @param head [String] the declaration without its block, e.g. "struct :address"
      # @param declaration [String] a declaration for the block's body, e.g. "string :city"
      # @return [String] the declaration with a block taking a parameter, e.g.
      #   "s.struct :address do |address| address.string :city end"
      def usage(name, head, declaration)
        var = name.to_s.match?(/\A[a-z_][a-z0-9_]*\z/) ? name : "inner"
        "s.#{head} do |#{var}| #{var}.#{declaration} end"
      end

      # @param name [String, Symbol] field name
      # @param type [Symbol, String] DSL type
      # @param repetition [Symbol] +:optional+ or +:required+
      # @param opts [Hash{Symbol => Object}] type options; +:values+ is taken out as the enum values
      #   and the rest go to Types.physical_attributes
      # @option opts [Array<String>, Hash] :values allowed values of a string/enum column
      # @return [Node] leaf node, not added to #nodes
      # @raise [ArgumentError] for an unknown type or invalid type options
      def leaf_node(name, type, repetition, opts)
        opts = opts.dup
        values = opts.delete(:values)
        attrs = Types.physical_attributes(type.to_sym, **opts)
        Node.new(name: name, repetition: repetition, enum_values: values, **attrs)
      end
    end
  end
end

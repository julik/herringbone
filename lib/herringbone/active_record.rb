# frozen_string_literal: true

module Herringbone
  class Schema
    # Builds a schema from an ActiveRecord model, so that the Hashes returned by
    # +record.attributes+ can be written directly:
    #
    #   schema = Herringbone::Schema.from_active_record(Order)
    #   Herringbone::Writer.open("orders.parquet", schema) do |w|
    #     Order.find_each { |order| w << order.attributes }
    #   end
    #
    # ActiveRecord is not required: this only uses what a model class exposes
    # (+columns+, +primary_key+ and, when present, +defined_enums+).
    #
    # only:   attribute names to include (Strings or Symbols)
    # except: attribute names to leave out
    # enums:  :string (default) writes enum attributes as STRING columns, :enum uses the
    #         Parquet ENUM annotation (which pyarrow/pandas read as binary). Either way the
    #         enum labels are written, and the writer rejects values outside the enum mapping
    #         (stored values such as 0/1 are accepted and written as their labels).
    def self.from_active_record(model, only: nil, except: nil, enums: :string)
      raise ArgumentError, "enums: must be :string or :enum" unless %i[string enum].include?(enums)
      only = only && Array(only).map(&:to_s)
      except = Array(except).map(&:to_s)
      defined_enums = model.respond_to?(:defined_enums) ? model.defined_enums.to_h { |k, v| [k.to_s, v] } : {}
      primary_keys = Array(model.respond_to?(:primary_key) ? model.primary_key : nil).map(&:to_s)

      builder = Builder.new
      model.columns.each do |column|
        name = column.name.to_s
        next if only && !only.include?(name)
        next if except.include?(name)
        primary = primary_keys.include?(name)
        nullable = column.null != false && !primary
        if (mapping = defined_enums[name])
          builder.enum(name, values: mapping.to_h, parquet_enum: enums == :enum, null: nullable)
        else
          ActiveRecordMapping.add_column(builder, column, nullable, primary)
        end
      end
      raise ArgumentError, "No columns selected from #{model}" if builder.nodes.empty?
      new(Node.new(name: "schema", repetition: :required, children: builder.nodes))
    end

    # Maps ActiveRecord column metadata to schema DSL types.
    #
    #   integer   by sql_type (smallint -> int16, bigint -> int64, ...) or by limit
    #             (1 -> int8, 2 -> int16, 8 -> int64, otherwise int32); "unsigned" -> uintN.
    #             Integer primary keys are always int64.
    #   float     double; float (32-bit) only for sql_type "float4"
    #   decimal   decimal(precision, scale); decimal(38, 9) when the column has no precision
    #   boolean, date, binary, uuid, json map to the same-named types (jsonb -> json)
    #   datetime, timestamp, timestamptz -> timestamp(micros, UTC); time -> time(micros)
    #   hstore    map<string, string>
    #   anything else (string, text, citext, inet, cidr, macaddr, ...) -> string
    #   Postgres arrays (column.array, or a sql_type ending in "[]") -> list of the element type
    module ActiveRecordMapping
      module_function

      DEFAULT_DECIMAL_PRECISION = 38
      DEFAULT_DECIMAL_SCALE = 9

      INTEGER_SQL_TYPES = {
        "tinyint" => 8, "int1" => 8,
        "smallint" => 16, "int2" => 16, "smallserial" => 16, "serial2" => 16,
        "mediumint" => 32, "int4" => 32, "serial" => 32, "serial4" => 32,
        "bigint" => 64, "int8" => 64, "bigserial" => 64, "serial8" => 64
      }.freeze

      def add_column(builder, column, nullable, primary)
        sql_type = column.respond_to?(:sql_type) ? column.sql_type.to_s.downcase : ""
        array = (column.respond_to?(:array) && column.array) || sql_type.end_with?("[]")
        sql_type = sql_type.sub(/(\[\d*\])+\z/, "")
        type = column.type&.to_sym

        if type == :hstore
          return builder.map(column.name, :string, :string, null: nullable) unless array
          return builder.list(column.name, null: nullable) { map :element, :string, :string }
        end

        dsl_type, opts = scalar_type(column, type, sql_type, primary)
        if array
          builder.list(column.name, dsl_type, null: nullable, **opts)
        else
          builder.column(column.name, dsl_type, null: nullable, **opts)
        end
      end

      def scalar_type(column, type, sql_type, primary)
        case type
        when :integer, :bigint then [integer_type(column, sql_type, primary), {}]
        when :float then [sql_type == "float4" ? :float : :double, {}]
        when :decimal, :money
          precision = column.respond_to?(:precision) ? column.precision : nil
          scale = column.respond_to?(:scale) ? column.scale : nil
          if precision.nil?
            precision = DEFAULT_DECIMAL_PRECISION
            scale ||= DEFAULT_DECIMAL_SCALE
          end
          [:decimal, { precision: precision, scale: scale || 0 }]
        when :boolean then [:boolean, {}]
        when :binary then [:binary, {}]
        when :date then [:date, {}]
        when :datetime, :timestamp, :timestamptz then [:timestamp, { unit: :micros, utc: true }]
        when :time then [:time, { unit: :micros }]
        when :json, :jsonb then [:json, {}]
        when :uuid then [:uuid, {}]
        else [:string, {}]
        end
      end

      # Named SQL types (smallint, bigint, ...) decide the width; a generic "integer"/"int"
      # uses the column limit in bytes, since e.g. SQLite reports `t.integer limit: 2` as "integer(2)".
      def integer_type(column, sql_type, primary)
        bits = INTEGER_SQL_TYPES[sql_type[/\A[a-z0-9]+/]]
        bits ||= case (column.respond_to?(:limit) ? column.limit : nil)
        when 1 then 8
        when 2 then 16
        when 5..8 then 64
        else 32
        end
        # Row ids can exceed 32 bits even where the column is declared "integer" (SQLite rowids)
        bits = 64 if primary
        unsigned = sql_type.include?("unsigned")
        return :"uint#{bits}" if unsigned
        { 8 => :int8, 16 => :int16, 32 => :int32, 64 => :int64 }.fetch(bits)
      end
    end
  end
end

module Herringbone
  # Exports an ActiveRecord model or relation as Parquet into an IO:
  #
  #   File.open("orders.parquet", "wb") do |file|
  #     Herringbone.export(Order.where(created_at: 1.year.ago..), file, compression: :zstd)
  #   end
  #
  # The schema comes from Schema.from_active_record (pass only:/except:/enums: to shape it, or
  # schema: to use your own). Records are loaded with find_each(batch_size:) when the relation
  # supports it, and each record's attributes are written, so memory stays bounded. Other options
  # go to Writer. Returns the number of rows written.
  def self.export(relation, io, schema: nil, only: nil, except: nil, enums: :string, batch_size: 1000, **writer_options)
    model = if relation.respond_to?(:klass) then relation.klass
    elsif relation.respond_to?(:columns) then relation
    end
    if schema.nil?
      raise ArgumentError, "Cannot derive a schema from #{relation.class}; pass schema:" unless model
      schema = Schema.from_active_record(model, only: only, except: except, enums: enums)
    end
    Writer.open(io, schema, **writer_options) do |writer|
      if relation.respond_to?(:find_each)
        relation.find_each(batch_size: batch_size) { |record| writer << record }
      else
        relation.each { |record| writer << record }
      end
      writer.rows_written
    end
  end
end


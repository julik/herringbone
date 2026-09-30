# frozen_string_literal: true

module Herringbone
  # Parquet file metadata structures, mirroring parquet.thrift.
  # Enums are plain i32 on the wire; constants below give them names.
  module Format
    module Type
      BOOLEAN = 0
      INT32 = 1
      INT64 = 2
      INT96 = 3
      FLOAT = 4
      DOUBLE = 5
      BYTE_ARRAY = 6
      FIXED_LEN_BYTE_ARRAY = 7
      NAMES = constants.to_h { |c| [const_get(c), c] }.freeze
    end

    module ConvertedType
      UTF8 = 0
      MAP = 1
      MAP_KEY_VALUE = 2
      LIST = 3
      ENUM = 4
      DECIMAL = 5
      DATE = 6
      TIME_MILLIS = 7
      TIME_MICROS = 8
      TIMESTAMP_MILLIS = 9
      TIMESTAMP_MICROS = 10
      UINT_8 = 11
      UINT_16 = 12
      UINT_32 = 13
      UINT_64 = 14
      INT_8 = 15
      INT_16 = 16
      INT_32 = 17
      INT_64 = 18
      JSON = 19
      BSON = 20
      INTERVAL = 21
      NAMES = constants.to_h { |c| [const_get(c), c] }.freeze
    end

    module Repetition
      REQUIRED = 0
      OPTIONAL = 1
      REPEATED = 2
      NAMES = constants.to_h { |c| [const_get(c), c] }.freeze
    end

    module Encoding
      PLAIN = 0
      PLAIN_DICTIONARY = 2
      RLE = 3
      BIT_PACKED = 4
      DELTA_BINARY_PACKED = 5
      DELTA_LENGTH_BYTE_ARRAY = 6
      DELTA_BYTE_ARRAY = 7
      RLE_DICTIONARY = 8
      BYTE_STREAM_SPLIT = 9
      NAMES = constants.to_h { |c| [const_get(c), c] }.freeze
    end

    module Codec
      UNCOMPRESSED = 0
      SNAPPY = 1
      GZIP = 2
      LZO = 3
      BROTLI = 4
      LZ4 = 5
      ZSTD = 6
      LZ4_RAW = 7
      NAMES = constants.to_h { |c| [const_get(c), c] }.freeze
    end

    module PageType
      DATA_PAGE = 0
      INDEX_PAGE = 1
      DICTIONARY_PAGE = 2
      DATA_PAGE_V2 = 3
      NAMES = constants.to_h { |c| [const_get(c), c] }.freeze
    end

    S = Thrift::Struct

    class SizeStatistics < S
      field 1, :unencoded_byte_array_data_bytes, :i64
      field 2, :repetition_level_histogram, [:list, :i64]
      field 3, :definition_level_histogram, [:list, :i64]
    end

    class Statistics < S
      field 1, :max, :binary
      field 2, :min, :binary
      field 3, :null_count, :i64
      field 4, :distinct_count, :i64
      field 5, :max_value, :binary
      field 6, :min_value, :binary
      field 7, :is_max_value_exact, :bool
      field 8, :is_min_value_exact, :bool
    end

    # Empty marker structs used inside unions
    class StringType < S; end
    class UUIDType < S; end
    class MapType < S; end
    class ListType < S; end
    class EnumType < S; end
    class DateType < S; end
    class Float16Type < S; end
    class NullType < S; end
    class JsonType < S; end
    class BsonType < S; end
    class MilliSeconds < S; end
    class MicroSeconds < S; end
    class NanoSeconds < S; end
    class TypeDefinedOrder < S; end
    class IndexPageHeader < S; end

    class VariantType < S
      field 1, :specification_version, :byte
    end

    class DecimalType < S
      field 1, :scale, :i32
      field 2, :precision, :i32
    end

    class TimeUnit < S
      field 1, :millis, MilliSeconds
      field 2, :micros, MicroSeconds
      field 3, :nanos, NanoSeconds

      def self.millis = new(millis: MilliSeconds.new)
      def self.micros = new(micros: MicroSeconds.new)
      def self.nanos = new(nanos: NanoSeconds.new)

      def to_sym
        if millis then :millis
        elsif micros then :micros
        elsif nanos then :nanos
        end
      end
    end

    class TimestampType < S
      field 1, :is_adjusted_to_utc, :bool
      field 2, :unit, TimeUnit
    end

    class TimeType < S
      field 1, :is_adjusted_to_utc, :bool
      field 2, :unit, TimeUnit
    end

    class IntType < S
      field 1, :bit_width, :byte
      field 2, :is_signed, :bool
    end

    class LogicalType < S
      field 1, :string, StringType
      field 2, :map, MapType
      field 3, :list, ListType
      field 4, :enum, EnumType
      field 5, :decimal, DecimalType
      field 6, :date, DateType
      field 7, :time, TimeType
      field 8, :timestamp, TimestampType
      field 10, :integer, IntType
      field 11, :unknown, NullType
      field 12, :json, JsonType
      field 13, :bson, BsonType
      field 14, :uuid, UUIDType
      field 15, :float16, Float16Type
      field 16, :variant, VariantType

      # Returns [kind_symbol, payload] for whichever union member is set
      def kind
        self.class.fields.each do |f|
          v = instance_variable_get(f.ivar)
          return [f.name, v] if v
        end
        nil
      end
    end

    class SchemaElement < S
      field 1, :type, :i32
      field 2, :type_length, :i32
      field 3, :repetition_type, :i32
      field 4, :name, :string
      field 5, :num_children, :i32
      field 6, :converted_type, :i32
      field 7, :scale, :i32
      field 8, :precision, :i32
      field 9, :field_id, :i32
      field 10, :logical_type, LogicalType
    end

    class DataPageHeader < S
      field 1, :num_values, :i32
      field 2, :encoding, :i32
      field 3, :definition_level_encoding, :i32
      field 4, :repetition_level_encoding, :i32
      field 5, :statistics, Statistics
    end

    class DictionaryPageHeader < S
      field 1, :num_values, :i32
      field 2, :encoding, :i32
      field 3, :is_sorted, :bool
    end

    class DataPageHeaderV2 < S
      field 1, :num_values, :i32
      field 2, :num_nulls, :i32
      field 3, :num_rows, :i32
      field 4, :encoding, :i32
      field 5, :definition_levels_byte_length, :i32
      field 6, :repetition_levels_byte_length, :i32
      field 7, :is_compressed, :bool
      field 8, :statistics, Statistics
    end

    class PageHeader < S
      field 1, :type, :i32
      field 2, :uncompressed_page_size, :i32
      field 3, :compressed_page_size, :i32
      field 4, :crc, :i32
      field 5, :data_page_header, DataPageHeader
      field 6, :index_page_header, IndexPageHeader
      field 7, :dictionary_page_header, DictionaryPageHeader
      field 8, :data_page_header_v2, DataPageHeaderV2
    end

    class KeyValue < S
      field 1, :key, :string
      field 2, :value, :string
    end

    class SortingColumn < S
      field 1, :column_idx, :i32
      field 2, :descending, :bool
      field 3, :nulls_first, :bool
    end

    class PageEncodingStats < S
      field 1, :page_type, :i32
      field 2, :encoding, :i32
      field 3, :count, :i32
    end

    class ColumnMetaData < S
      field 1, :type, :i32
      field 2, :encodings, [:list, :i32]
      field 3, :path_in_schema, [:list, :string]
      field 4, :codec, :i32
      field 5, :num_values, :i64
      field 6, :total_uncompressed_size, :i64
      field 7, :total_compressed_size, :i64
      field 8, :key_value_metadata, [:list, KeyValue]
      field 9, :data_page_offset, :i64
      field 10, :index_page_offset, :i64
      field 11, :dictionary_page_offset, :i64
      field 12, :statistics, Statistics
      field 13, :encoding_stats, [:list, PageEncodingStats]
      field 14, :bloom_filter_offset, :i64
      field 15, :bloom_filter_length, :i32
      field 16, :size_statistics, SizeStatistics
    end

    class ColumnChunk < S
      field 1, :file_path, :string
      field 2, :file_offset, :i64
      field 3, :meta_data, ColumnMetaData
      field 4, :offset_index_offset, :i64
      field 5, :offset_index_length, :i32
      field 6, :column_index_offset, :i64
      field 7, :column_index_length, :i32
      field 9, :encrypted_column_metadata, :binary
    end

    class RowGroup < S
      field 1, :columns, [:list, ColumnChunk]
      field 2, :total_byte_size, :i64
      field 3, :num_rows, :i64
      field 4, :sorting_columns, [:list, SortingColumn]
      field 5, :file_offset, :i64
      field 6, :total_compressed_size, :i64
      field 7, :ordinal, :i16
    end

    module BoundaryOrder
      UNORDERED = 0
      ASCENDING = 1
      DESCENDING = 2
      NAMES = constants.to_h { |c| [const_get(c), c] }.freeze
    end

    # Page index structures (stored between the row groups and the footer)
    class PageLocation < S
      field 1, :offset, :i64
      field 2, :compressed_page_size, :i32
      field 3, :first_row_index, :i64
    end

    class OffsetIndex < S
      field 1, :page_locations, [:list, PageLocation]
      field 2, :unencoded_byte_array_data_bytes, [:list, :i64]
    end

    class ColumnIndex < S
      field 1, :null_pages, [:list, :bool]
      field 2, :min_values, [:list, :binary]
      field 3, :max_values, [:list, :binary]
      field 4, :boundary_order, :i32
      field 5, :null_counts, [:list, :i64]
      field 6, :repetition_level_histograms, [:list, :i64]
      field 7, :definition_level_histograms, [:list, :i64]
    end

    class ColumnOrder < S
      field 1, :type_order, TypeDefinedOrder
    end

    class FileMetaData < S
      field 1, :version, :i32
      field 2, :schema, [:list, SchemaElement]
      field 3, :num_rows, :i64
      field 4, :row_groups, [:list, RowGroup]
      field 5, :key_value_metadata, [:list, KeyValue]
      field 6, :created_by, :string
      field 7, :column_orders, [:list, ColumnOrder]
    end
  end
end

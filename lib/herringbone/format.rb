# frozen_string_literal: true

module Herringbone
  # Parquet file metadata structures, mirroring parquet.thrift.
  # Enums are plain i32 on the wire; constants below give them names.
  module Format
    # Physical storage types (+Type+ enum in parquet.thrift).
    module Type
      # Single bit, bit-packed in PLAIN encoding
      BOOLEAN = 0
      # 32-bit signed little-endian integer
      INT32 = 1
      # 64-bit signed little-endian integer
      INT64 = 2
      # 96-bit legacy timestamp (nanoseconds of day + Julian day), deprecated by the spec
      INT96 = 3
      # IEEE 754 single precision
      FLOAT = 4
      # IEEE 754 double precision
      DOUBLE = 5
      # Variable-length bytes, length-prefixed in PLAIN encoding
      BYTE_ARRAY = 6
      # Bytes of the fixed length given by +SchemaElement#type_length+
      FIXED_LEN_BYTE_ARRAY = 7
      # Constant name for each enum value
      NAMES = constants.to_h { |c| [const_get(c), c] }.freeze
    end

    # Legacy type annotations (+ConvertedType+ enum), superseded by LogicalType but still
    # written alongside it for older readers.
    module ConvertedType
      # UTF-8 encoded BYTE_ARRAY
      UTF8 = 0
      # Group annotated as a map
      MAP = 1
      # Repeated key/value group inside a MAP
      MAP_KEY_VALUE = 2
      # Group annotated as a list
      LIST = 3
      # BYTE_ARRAY holding an enum label
      ENUM = 4
      # Decimal with scale and precision from the SchemaElement
      DECIMAL = 5
      # INT32 days since the Unix epoch
      DATE = 6
      # INT32 milliseconds since midnight
      TIME_MILLIS = 7
      # INT64 microseconds since midnight
      TIME_MICROS = 8
      # INT64 milliseconds since the Unix epoch, UTC
      TIMESTAMP_MILLIS = 9
      # INT64 microseconds since the Unix epoch, UTC
      TIMESTAMP_MICROS = 10
      # Unsigned 8-bit integer stored in INT32
      UINT_8 = 11
      # Unsigned 16-bit integer stored in INT32
      UINT_16 = 12
      # Unsigned 32-bit integer stored in INT32
      UINT_32 = 13
      # Unsigned 64-bit integer stored in INT64
      UINT_64 = 14
      # Signed 8-bit integer stored in INT32
      INT_8 = 15
      # Signed 16-bit integer stored in INT32
      INT_16 = 16
      # Signed 32-bit integer stored in INT32
      INT_32 = 17
      # Signed 64-bit integer stored in INT64
      INT_64 = 18
      # UTF-8 JSON document in a BYTE_ARRAY
      JSON = 19
      # BSON document in a BYTE_ARRAY
      BSON = 20
      # 12-byte FIXED_LEN_BYTE_ARRAY of months, days and milliseconds
      INTERVAL = 21
      # Constant name for each enum value
      NAMES = constants.to_h { |c| [const_get(c), c] }.freeze
    end

    # Field repetition (+FieldRepetitionType+ enum).
    module Repetition
      # Exactly one value
      REQUIRED = 0
      # Zero or one value
      OPTIONAL = 1
      # Zero or more values
      REPEATED = 2
      # Constant name for each enum value
      NAMES = constants.to_h { |c| [const_get(c), c] }.freeze
    end

    # Value and level encodings (+Encoding+ enum). Value 1 (GROUP_VAR_INT) was never used.
    module Encoding
      # Values back to back in their natural binary form
      PLAIN = 0
      # Deprecated name for a dictionary-encoded page (and a PLAIN dictionary page) in format v1
      PLAIN_DICTIONARY = 2
      # RLE / bit-packing hybrid, used for levels and booleans
      RLE = 3
      # Deprecated bit-packed levels
      BIT_PACKED = 4
      # Delta encoding for INT32/INT64
      DELTA_BINARY_PACKED = 5
      # Delta-encoded lengths followed by the concatenated bytes
      DELTA_LENGTH_BYTE_ARRAY = 6
      # Incremental (prefix-shared) encoding for byte arrays
      DELTA_BYTE_ARRAY = 7
      # Dictionary indices in RLE / bit-packing hybrid form
      RLE_DICTIONARY = 8
      # Bytes of each value split into separate streams
      BYTE_STREAM_SPLIT = 9
      # Constant name for each enum value
      NAMES = constants.to_h { |c| [const_get(c), c] }.freeze
    end

    # Page compression codecs (+CompressionCodec+ enum).
    module Codec
      # No compression
      UNCOMPRESSED = 0
      # Raw Snappy
      SNAPPY = 1
      # Gzip (deflate with gzip header)
      GZIP = 2
      # LZO
      LZO = 3
      # Brotli
      BROTLI = 4
      # Deprecated Hadoop-framed LZ4
      LZ4 = 5
      # Zstandard
      ZSTD = 6
      # LZ4 block format without framing
      LZ4_RAW = 7
      # Constant name for each enum value
      NAMES = constants.to_h { |c| [const_get(c), c] }.freeze
    end

    # Page types (+PageType+ enum).
    module PageType
      # Data page, format v1
      DATA_PAGE = 0
      # Index page (never written in practice)
      INDEX_PAGE = 1
      # Dictionary page, precedes the data pages of a column chunk
      DICTIONARY_PAGE = 2
      # Data page, format v2 (levels stored uncompressed ahead of the values)
      DATA_PAGE_V2 = 3
      # Constant name for each enum value
      NAMES = constants.to_h { |c| [const_get(c), c] }.freeze
    end

    # Short alias for the struct base class used by every definition below
    S = Thrift::Struct

    # Byte and level-histogram statistics for a page or column chunk.
    class SizeStatistics < S
      field 1, :unencoded_byte_array_data_bytes, :i64
      field 2, :repetition_level_histogram, [:list, :i64]
      field 3, :definition_level_histogram, [:list, :i64]
    end

    # Min/max and count statistics for a page or column chunk. +max+/+min+ are the deprecated
    # signed-order fields; +max_value+/+min_value+ use the column's sort order.
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

    # STRING logical type.
    class StringType < S; end

    # UUID logical type (16-byte FIXED_LEN_BYTE_ARRAY).
    class UUIDType < S; end

    # MAP logical type.
    class MapType < S; end

    # LIST logical type.
    class ListType < S; end

    # ENUM logical type.
    class EnumType < S; end

    # DATE logical type.
    class DateType < S; end

    # FLOAT16 logical type (2-byte FIXED_LEN_BYTE_ARRAY, little-endian half precision).
    class Float16Type < S; end

    # UNKNOWN logical type: the column is always null.
    class NullType < S; end

    # JSON logical type.
    class JsonType < S; end

    # BSON logical type.
    class BsonType < S; end

    # Millisecond member of the TimeUnit union.
    class MilliSeconds < S; end

    # Microsecond member of the TimeUnit union.
    class MicroSeconds < S; end

    # Nanosecond member of the TimeUnit union.
    class NanoSeconds < S; end

    # ColumnOrder member: values are ordered according to their (logical) type.
    class TypeDefinedOrder < S; end

    # Header of an index page; has no fields in the spec.
    class IndexPageHeader < S; end

    # VARIANT logical type.
    class VariantType < S
      field 1, :specification_version, :byte
    end

    # DECIMAL logical type: unscaled integer value divided by 10 to the power of +scale+.
    class DecimalType < S
      field 1, :scale, :i32
      field 2, :precision, :i32
    end

    # Union of time units for TIME and TIMESTAMP; exactly one member is set.
    class TimeUnit < S
      field 1, :millis, MilliSeconds
      field 2, :micros, MicroSeconds
      field 3, :nanos, NanoSeconds

      # @return [TimeUnit] a unit with the +millis+ member set
      def self.millis = new(millis: MilliSeconds.new)
      # @return [TimeUnit] a unit with the +micros+ member set
      def self.micros = new(micros: MicroSeconds.new)
      # @return [TimeUnit] a unit with the +nanos+ member set
      def self.nanos = new(nanos: NanoSeconds.new)

      # @return [Symbol, nil] +:millis+, +:micros+ or +:nanos+, or nil when no member is set
      def to_sym
        if millis then :millis
        elsif micros then :micros
        elsif nanos then :nanos
        end
      end
    end

    # TIMESTAMP logical type.
    class TimestampType < S
      field 1, :is_adjusted_to_utc, :bool
      field 2, :unit, TimeUnit
    end

    # TIME logical type.
    class TimeType < S
      field 1, :is_adjusted_to_utc, :bool
      field 2, :unit, TimeUnit
    end

    # INTEGER logical type (bit width 8, 16, 32 or 64; signed or unsigned).
    class IntType < S
      field 1, :bit_width, :byte
      field 2, :is_signed, :bool
    end

    # Union of logical type annotations; exactly one member is set. Field id 9 is reserved
    # (for INTERVAL) in parquet.thrift.
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
      # @return [Array(Symbol, Thrift::Struct), nil] member name and its struct, or nil when
      #   no member is set
      def kind
        self.class.fields.each do |f|
          v = instance_variable_get(f.ivar)
          return [f.name, v] if v
        end
        nil
      end
    end

    # One node of the schema, flattened depth-first into +FileMetaData#schema+. Groups carry
    # +num_children+; leaves carry the physical +type+.
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

    # Header of a v1 data page: levels and values share one compressed block.
    class DataPageHeader < S
      field 1, :num_values, :i32
      field 2, :encoding, :i32
      field 3, :definition_level_encoding, :i32
      field 4, :repetition_level_encoding, :i32
      field 5, :statistics, Statistics
    end

    # Header of a dictionary page.
    class DictionaryPageHeader < S
      field 1, :num_values, :i32
      field 2, :encoding, :i32
      field 3, :is_sorted, :bool
    end

    # Header of a v2 data page: levels are stored uncompressed before the (optionally
    # compressed) values, with their byte lengths given here.
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

    # Header preceding every page; +type+ (a PageType) says which sub-header is set.
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

    # Application-defined key/value metadata entry.
    class KeyValue < S
      field 1, :key, :string
      field 2, :value, :string
    end

    # Sort order of one column within a row group.
    class SortingColumn < S
      field 1, :column_idx, :i32
      field 2, :descending, :bool
      field 3, :nulls_first, :bool
    end

    # Number of pages of a given type and encoding in a column chunk.
    class PageEncodingStats < S
      field 1, :page_type, :i32
      field 2, :encoding, :i32
      field 3, :count, :i32
    end

    # Metadata of a column chunk: where its pages are, how they are encoded and compressed.
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

    # Modular encryption (Encryption.md)

    # Algorithm settings shared by both algorithms: the AAD prefix (unless readers must supply
    # it) and the file's unique id, which together make the file's part of every module's AAD.
    class AesGcmV1 < S
      field 1, :aad_prefix, :binary
      field 2, :aad_file_unique, :binary
      field 3, :supply_aad_prefix, :bool
    end

    # AES_GCM_CTR_V1: like AesGcmV1, but pages are encrypted with AES-CTR, without a tag.
    class AesGcmCtrV1 < S
      field 1, :aad_prefix, :binary
      field 2, :aad_file_unique, :binary
      field 3, :supply_aad_prefix, :bool
    end

    # Union of encryption algorithms; exactly one member is set.
    class EncryptionAlgorithm < S
      field 1, :aes_gcm_v1, AesGcmV1
      field 2, :aes_gcm_ctr_v1, AesGcmCtrV1

      # @return [AesGcmV1, AesGcmCtrV1, nil] whichever member is set
      def settings = aes_gcm_v1 || aes_gcm_ctr_v1
    end

    # ColumnCryptoMetaData member: the column is encrypted with the footer key.
    class EncryptionWithFooterKey < S; end

    # ColumnCryptoMetaData member: the column is encrypted with a key of its own.
    class EncryptionWithColumnKey < S
      field 1, :path_in_schema, [:list, :string]
      field 2, :key_metadata, :binary
    end

    # Union saying which key an encrypted column uses; exactly one member is set.
    class ColumnCryptoMetaData < S
      field 1, :encryption_with_footer_key, EncryptionWithFooterKey
      field 2, :encryption_with_column_key, EncryptionWithColumnKey
    end

    # Stored in the clear before an encrypted footer (files with the PARE magic).
    class FileCryptoMetaData < S
      field 1, :encryption_algorithm, EncryptionAlgorithm
      field 2, :key_metadata, :binary
    end

    # One column of a row group, plus the locations of its page index. In encrypted columns
    # +crypto_metadata+ names the key, and +encrypted_column_metadata+ holds the ColumnMetaData
    # when it is encrypted on its own.
    class ColumnChunk < S
      field 1, :file_path, :string
      field 2, :file_offset, :i64
      field 3, :meta_data, ColumnMetaData
      field 4, :offset_index_offset, :i64
      field 5, :offset_index_length, :i32
      field 6, :column_index_offset, :i64
      field 7, :column_index_length, :i32
      field 8, :crypto_metadata, ColumnCryptoMetaData
      field 9, :encrypted_column_metadata, :binary
    end

    # A horizontal slice of the file, holding one ColumnChunk per leaf column.
    class RowGroup < S
      field 1, :columns, [:list, ColumnChunk]
      field 2, :total_byte_size, :i64
      field 3, :num_rows, :i64
      field 4, :sorting_columns, [:list, SortingColumn]
      field 5, :file_offset, :i64
      field 6, :total_compressed_size, :i64
      field 7, :ordinal, :i16
    end

    # Ordering of the per-page min/max values in a ColumnIndex (+BoundaryOrder+ enum).
    module BoundaryOrder
      # No particular order
      UNORDERED = 0
      # Min and max values both non-decreasing from page to page
      ASCENDING = 1
      # Min and max values both non-increasing from page to page
      DESCENDING = 2
      # Constant name for each enum value
      NAMES = constants.to_h { |c| [const_get(c), c] }.freeze
    end

    # Page index structures (stored between the row groups and the footer)

    # Location of one data page within the file.
    class PageLocation < S
      field 1, :offset, :i64
      field 2, :compressed_page_size, :i32
      field 3, :first_row_index, :i64
    end

    # Offset index of a column chunk: the location of each of its data pages.
    class OffsetIndex < S
      field 1, :page_locations, [:list, PageLocation]
      field 2, :unencoded_byte_array_data_bytes, [:list, :i64]
    end

    # Column index of a column chunk: per-page min/max values and null information.
    class ColumnIndex < S
      field 1, :null_pages, [:list, :bool]
      field 2, :min_values, [:list, :binary]
      field 3, :max_values, [:list, :binary]
      field 4, :boundary_order, :i32
      field 5, :null_counts, [:list, :i64]
      field 6, :repetition_level_histograms, [:list, :i64]
      field 7, :definition_level_histograms, [:list, :i64]
    end

    # Union describing how min/max statistics of a column are ordered.
    class ColumnOrder < S
      field 1, :type_order, TypeDefinedOrder
    end

    # The file footer: schema, row groups and file-level metadata. The encryption fields are
    # only set in encrypted files with a plaintext footer.
    class FileMetaData < S
      field 1, :version, :i32
      field 2, :schema, [:list, SchemaElement]
      field 3, :num_rows, :i64
      field 4, :row_groups, [:list, RowGroup]
      field 5, :key_value_metadata, [:list, KeyValue]
      field 6, :created_by, :string
      field 7, :column_orders, [:list, ColumnOrder]
      field 8, :encryption_algorithm, EncryptionAlgorithm
      field 9, :footer_signing_key_metadata, :binary
    end

    # Bloom filters (BloomFilter.md). Each union has a single member, an empty struct.

    # Split block bloom filter algorithm.
    class SplitBlockAlgorithm < S; end

    # XXH64 hash with seed 0.
    class XxHash < S; end

    # Bloom filter bitset stored uncompressed.
    class BloomFilterUncompressed < S; end

    # Union of bloom filter algorithms.
    class BloomFilterAlgorithm < S
      field 1, :block, SplitBlockAlgorithm
    end

    # Union of hash functions used to feed the bloom filter.
    class BloomFilterHash < S
      field 1, :xxhash, XxHash
    end

    # Union of bloom filter compressions.
    class BloomFilterCompression < S
      field 1, :uncompressed, BloomFilterUncompressed
    end

    # Header preceding the bitset of a column chunk's bloom filter.
    class BloomFilterHeader < S
      field 1, :num_bytes, :i32
      field 2, :algorithm, BloomFilterAlgorithm
      field 3, :hash_function, BloomFilterHash # "hash" in parquet.thrift; renamed to keep Object#hash
      field 4, :compression, BloomFilterCompression
    end
  end
end

# frozen_string_literal: true

module Herringbone
  # Rewrites a Parquet file with rows removed or column values replaced, for GDPR erasure ("forget
  # me") and pseudonymization. A Redaction is built once and applied to any number of files, one
  # file in and one file out:
  #
  #   forget = Herringbone::Redaction.new do
  #     where(user_id: 42).delete
  #     where(email: "anna@example.com").replace(email: nil, name: nil)
  #     replace(:phone) { |phone| phone&.gsub(/\d(?=\d{3})/, "#") }
  #     drop :ssn
  #   end
  #   File.open("in.parquet", "rb") do |input|
  #     File.open("out.parquet", "wb") { |output| forget.apply(input, output) }
  #   end
  #
  # Statements apply in declared order, per row: a deleted row is gone for later statements, and
  # later statements (their conditions and their blocks) see what earlier ones replaced.
  #
  # Row groups no statement touches are copied byte for byte. A row group where only leaf columns
  # are replaced gets just those column chunks re-encoded. A row group with deleted rows, or with a
  # nested field replaced as a whole, is rewritten. Either way no deleted or replaced value is
  # left in data pages, dictionary pages, statistics, the page index or bloom filters.
  #
  # The block given to Redaction.new is run with instance_exec, so it sees local variables and
  # constants but not the methods of the object it was written in. Take a block argument
  # (+Redaction.new { |r| r.where(...).delete }+) when those are needed.
  class Redaction
    # One statement of a Redaction
    #
    # @!attribute kind
    #   @return [Symbol] +:delete+ or +:replace+
    # @!attribute where
    #   @return [Hash{String, Symbol => Object}, nil] conditions as given to #where, nil for every row
    # @!attribute targets
    #   @return [Array<String>] columns to replace (top-level names or dotted struct member paths)
    # @!attribute constants
    #   @return [Hash{String => Object}] column => value, for a replace without a block
    # @!attribute block
    #   @return [Proc, nil] computes the replacement values
    Statement = Struct.new(:kind, :where, :targets, :constants, :block)

    # What #apply did, for the audit trail an erasure needs
    #
    # @!attribute rows_read
    #   @return [Integer] rows decoded (rows of row groups that were copied unread are not counted)
    # @!attribute rows_deleted
    #   @return [Integer] rows removed
    # @!attribute rows_changed
    #   @return [Integer] rows kept where at least one replace produced a different value
    # @!attribute row_groups
    #   @return [Hash{Symbol => Integer}] +{copied:, rewritten:}+ row group counts
    Report = Struct.new(:rows_read, :rows_deleted, :rows_changed, :row_groups, keyword_init: true)

    # Rows selected with Redaction#where, waiting for a verb: #delete or #replace
    class Scope
      # @return [Hash{String, Symbol => Object}] the conditions given to Redaction#where
      attr_reader :conditions

      # @param redaction [Redaction] the redaction the statement is added to
      # @param conditions [Hash{String, Symbol => Object}] column => condition, as Reader#read(where:)
      def initialize(redaction, conditions)
        @redaction = redaction
        @conditions = conditions
        @used = false
      end

      # @return [Boolean] whether a verb was called on this scope
      def used? = @used

      # Removes the matching rows
      #
      # @return [Redaction] the redaction, for chaining
      def delete
        @used = true
        @redaction.add_statement(Statement.new(:delete, @conditions, [], {}, nil))
      end

      # Replaces values in the matching rows, see Redaction#replace
      #
      # @param columns [Array<String, Symbol>] columns whose values the block computes
      # @param constants [Hash{String, Symbol => Object}] column => value to set
      # @option constants [Object] :any_column value to store in that column (keys are column names)
      # @yield [value, row] once per matching row and named column
      # @yieldparam value [Object] the current value
      # @yieldparam row [Hash{String => Object}] the whole row, only when the block takes two parameters
      # @yieldreturn [Object] the value to store
      # @return [Redaction] the redaction, for chaining
      # @raise [ArgumentError] when given both or neither of +constants+ and a block
      def replace(*columns, **constants, &block)
        statement = Redaction.replace_statement(@conditions, columns, constants, block)
        @used = true
        @redaction.add_statement(statement)
      end
    end

    # @return [Array<Statement>] the statements, in declared order
    attr_reader :statements

    # @return [Array<String>] fields and struct members to remove from the schema
    attr_reader :drops

    # Builds a redaction. The block declares the statements, see the class description.
    #
    # @yield [redaction] declares the statements; run with instance_exec when it takes no argument
    # @yieldparam redaction [Redaction] the redaction being built, when the block takes it
    # @yieldreturn [void]
    # @raise [ArgumentError] for an invalid statement, or a #where left without a verb
    def initialize(&block)
      @statements = []
      @drops = []
      @scopes = []
      if block
        (block.arity == 1) ? yield(self) : instance_exec(&block)
        check_scopes!
      end
    end

    # Selects the rows the next verb applies to. Takes what Reader#read(where:) takes: values,
    # Arrays (IN), Ranges, nil (IS NULL), callables and dotted struct member paths, all of which
    # must hold.
    #
    #   where(user_id: 42).delete
    #   where("address.city" => "Amsterdam", created_at: ..cutoff).replace(name: nil)
    #
    # @param conditions [Hash{String, Symbol => Object}, nil] column => condition
    # @param more [Hash{String, Symbol => Object}] more conditions, as keyword arguments
    # @option more [Object] :any_column condition on that column (keys are column names)
    # @return [Scope] call #delete or #replace on it
    # @raise [ArgumentError] when there are no conditions
    def where(conditions = nil, **more)
      raise ArgumentError, "where expects a Hash of column => condition" unless conditions.nil? || conditions.is_a?(Hash)
      conditions = (conditions || {}).merge(more)
      raise ArgumentError, "where needs at least one condition" if conditions.empty?
      scope = Scope.new(self, conditions)
      @scopes << scope
      scope
    end

    # Replaces values in every row (or, after #where, in the matching rows). Either constants:
    #
    #   replace(email: nil, name: "[deleted]")
    #
    # or column names and a block computing each value from the current one, and from the whole
    # row (a Hash with String keys, as Reader returns it) when the block takes two parameters:
    #
    #   replace(:email) { |email| email && OpenSSL::HMAC.hexdigest("SHA256", key, email) }
    #   replace(:name) { |name, row| row["consent"] ? name : nil }
    #
    # A column is a top-level field or a struct member by dotted path. Values inside a list or map
    # are replaced by replacing the whole field with a block that receives the Array or Hash.
    # A struct member of a row whose struct is null is left alone.
    #
    # @param columns [Array<String, Symbol>] columns whose values the block computes
    # @param constants [Hash{String, Symbol => Object}] column => value to set
    # @option constants [Object] :any_column value to store in that column (keys are column names)
    # @yield [value, row] once per row and named column
    # @yieldparam value [Object] the current value
    # @yieldparam row [Hash{String => Object}] the whole row, only when the block takes two parameters
    # @yieldreturn [Object] the value to store
    # @return [Redaction] self
    # @raise [ArgumentError] when given both or neither of +constants+ and a block
    def replace(*columns, **constants, &block)
      add_statement(Redaction.replace_statement(nil, columns, constants, block))
    end

    # Removes columns from the schema: top-level fields, or struct members by dotted path
    #
    # @param columns [Array<String, Symbol>] columns to remove
    # @return [Redaction] self
    # @raise [ArgumentError] when no column is given
    def drop(*columns)
      raise ArgumentError, "drop needs at least one column" if columns.empty?
      @drops.concat(columns.map(&:to_s))
      self
    end

    # Internal (used by Scope): appends a statement
    #
    # @param statement [Statement] the statement to add
    # @return [Redaction] self
    def add_statement(statement)
      @statements << statement
      self
    end

    # Whether #apply would change +input_io+: true when a column is dropped, when a replace without
    # #where meets a non-empty file, or when some row matches a #where. Reads as little as it can:
    # row groups are ruled out with statistics, bloom filters and the page index first, and only
    # the columns the conditions name are read for the rest.
    #
    # @param input_io [IO, StringIO] the Parquet file, read with #seek and #read
    # @return [Boolean]
    # @raise [ArgumentError] when the redaction does not fit the file's schema
    def affects?(input_io)
      check_scopes!
      Rewriter.new(self, input_io).affects?
    end

    # Writes the redacted copy of +input_io+ to +output_io+. The redaction is checked against the
    # file's schema first, so a missing column, a nil for a required column or a #where without a
    # verb raise before anything is written. The output is left unfinished (no footer) when an
    # error happens later, for instance a block returning a value its column cannot store.
    #
    # @param input_io [IO, StringIO] the Parquet file, read with #seek and #read; not closed
    # @param output_io [IO, #write] destination, written sequentially; not closed
    # @param writer_options [Hash{Symbol => Object}] Writer options for the re-encoded column chunks
    #   (+compression:+, +bloom_filters:+, +page_rows:+, +dictionary:+...), and +metadata:+ to
    #   replace the footer key/value metadata instead of copying it
    # @option writer_options [Symbol] :compression (codec of each source chunk) codec for re-encoded chunks
    # @option writer_options [Boolean, Array<String>, Hash{String => Boolean, Hash}] :bloom_filters (nil)
    #   columns whose re-encoded chunks get a bloom filter, besides those whose source chunk had one
    # @option writer_options [Hash{String => String}] :metadata (the input's) footer key/value metadata
    # @option writer_options [Integer] :page_bytes (1MB) approximate uncompressed data page size
    # @option writer_options [Integer] :page_rows (20_000) maximum rows per data page
    # @option writer_options [Integer] :data_page_version (1) 1 or 2
    # @option writer_options [Boolean, Array<String>] :dictionary (true) see Writer
    # @option writer_options [Hash{String => Symbol}] :encodings ({}) see Writer
    # @return [Report] what was done
    # @raise [ArgumentError] when the redaction does not fit the file's schema, or for a writer
    #   option that does not apply (+row_group_bytes:+, +row_group_rows:+)
    # @raise [EncodeError] when a replacement value cannot be written to its column
    def apply(input_io, output_io, **writer_options)
      check_scopes!
      Rewriter.new(self, input_io).apply(output_io, **writer_options)
    end

    # Builds a replace statement from the arguments of #replace
    #
    # @param where [Hash{String, Symbol => Object}, nil] conditions, nil for every row
    # @param columns [Array<String, Symbol>] columns for the block
    # @param constants [Hash{String, Symbol => Object}] column => value
    # @param block [Proc, nil] computes the values
    # @return [Statement]
    # @raise [ArgumentError] when given both or neither of +constants+ and a block
    def self.replace_statement(where, columns, constants, block)
      if block
        unless constants.empty?
          raise ArgumentError, "replace takes column names and a block, or column => value pairs, not both"
        end
        raise ArgumentError, "replace with a block needs the names of the columns to replace" if columns.empty?
        Statement.new(:replace, where, columns.map(&:to_s).uniq, {}, block)
      else
        unless columns.empty?
          raise ArgumentError, "replace(#{columns.map(&:inspect).join(", ")}) needs a block computing the " \
            "values; use replace(column: value) to set constants"
        end
        raise ArgumentError, "replace needs columns: replace(email: nil) or replace(:email) { |v| ... }" if constants.empty?
        constants = constants.transform_keys(&:to_s)
        Statement.new(:replace, where, constants.keys, constants, nil)
      end
    end

    private

    # @return [void]
    # @raise [ArgumentError] when a #where was not followed by #delete or #replace
    def check_scopes!
      idle = @scopes.reject(&:used?)
      return if idle.empty?
      raise ArgumentError, "where(#{idle.first.conditions.inspect}) needs a verb: .delete or .replace(...)"
    end
  end
end

require_relative "redaction/rewriter"

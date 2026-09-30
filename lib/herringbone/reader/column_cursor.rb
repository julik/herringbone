# frozen_string_literal: true

module Herringbone
  class Reader
    # Walks the pages of one leaf column chunk and hands out the entries (levels and values)
    # of the next +k+ rows. Only the current page is held in memory. A row starts at an entry
    # with repetition level 0 and may continue over any number of following pages.
    class ColumnCursor
      EMPTY = [].freeze

      def initialize(chunk_reader)
        @src = chunk_reader
        col = chunk_reader.column
        @path = col.dotted_path
        @max_def = col.max_definition_level
        @repeated = col.max_repetition_level.positive?
        @defs = @reps = nil
        @vals = EMPTY
        @n = 0   # entries in the current page
        @ei = 0  # entry cursor
        @vi = 0  # value cursor
        @starts = EMPTY # entry index of each row start in the current page (repeated columns)
        @ri = 0 # next row start in @starts
      end

      # [definition_levels, repetition_levels, values] of the next +k+ rows. Levels are nil
      # when the column's max level is 0. The returned arrays must not be modified.
      def take(k)
        pieces = @repeated ? take_repeated(k) : take_flat(k)
        return pieces.first if pieces.size == 1
        defs = @max_def.positive? ? [] : nil
        reps = @repeated ? [] : nil
        vals = []
        pieces.each do |d, r, v|
          defs&.concat(d)
          reps&.concat(r)
          vals.concat(v)
        end
        [defs, reps, vals]
      end

      private

      def take_flat(k)
        pieces = []
        while k > 0
          load_page! if @ei >= @n
          t = @n - @ei
          t = k if k < t
          pieces << slice(@ei, @ei + t)
          k -= t
        end
        pieces
      end

      def take_repeated(k)
        pieces = []
        while k > 0
          if @ei >= @n
            load_page!
            next if @n.zero?
            raise FormatError, "Column #{@path}: page does not start at a row boundary" unless @starts.first == 0
          end
          avail = @starts.size - @ri
          t = avail < k ? avail : k
          stop = @ri + t < @starts.size ? @starts[@ri + t] : @n
          pieces << slice(@ei, stop)
          @ri += t
          k -= t
          next unless @ei == @n

          # The page's last row may continue in the following pages
          while load_page
            first = @starts.first
            if first.nil?
              pieces << slice(0, @n)
            else
              pieces << slice(0, first) if first > 0
              break
            end
          end
        end
        pieces
      end

      # Entries [from, to) of the current page; advances the cursors to +to+
      def slice(from, to)
        len = to - from
        whole = from.zero? && len == @n
        defs = @defs && (whole ? @defs : @defs[from, len])
        reps = @reps && (whole ? @reps : @reps[from, len])
        nv = if whole || @vals.size == @n
          len
        else
          defs.count(@max_def)
        end
        vals = whole ? @vals : @vals[@vi, nv]
        vals = vals.map!(&@conv) if @conv
        @ei = to
        @vi += nv
        [defs, reps, vals]
      end

      def load_page!
        return if load_page
        raise FormatError, "Column #{@path}: ran out of pages after #{@src.seen} of #{@src.total} values"
      end

      # Loads the next data page; false at the end of the chunk
      def load_page
        page = @src.next_page or return false
        @defs, @reps, @vals = page
        @conv = @src.page_converter
        @n = (@defs || @reps || @vals).size
        if @defs && @vals.size > @n
          raise FormatError, "Column #{@path}: page has more values than definition levels"
        end
        @ei = 0
        @vi = 0
        @ri = 0
        @starts = @repeated ? row_starts(@reps) : EMPTY
        true
      end

      def row_starts(reps)
        starts = []
        i = 0
        n = reps.size
        while i < n
          starts << i if reps[i] == 0
          i += 1
        end
        starts
      end
    end
  end
end

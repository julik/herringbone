# frozen_string_literal: true

module Herringbone
  class Reader
    # Walks the pages of one leaf column chunk and hands out the entries (levels and values)
    # of the next +k+ rows. Pages are decoded incrementally (see PageStream), so only the
    # entries of the requested rows (plus a small lookahead of levels for repeated columns)
    # become Ruby objects. A row starts at an entry with repetition level 0 and may continue
    # over any number of following pages.
    class ColumnCursor
      # Levels decoded ahead at a time when looking for row starts in repeated columns
      LOOKAHEAD = 4096

      def initialize(chunk_reader)
        @src = chunk_reader
        col = chunk_reader.column
        @path = col.dotted_path
        @max_def = col.max_definition_level
        @repeated = col.max_repetition_level.positive?
        @page = nil
        # Repeated columns: levels decoded from the current page but not handed out yet
        @bd = @br = nil
        @bi = 0
        @started = false
        @row = 0       # rows handed out or skipped so far
        @page_idx = -1 # index of the current data page within the chunk
      end

      # Rows handed out or skipped so far
      attr_reader :row

      # Moves forward to row +target+ of the chunk (0-based). With an OffsetIndex, pages before
      # the one holding +target+ are not read at all; otherwise rows are skipped page by page,
      # decoding levels but not building values.
      def seek(target)
        raise ArgumentError, "Cannot seek backwards (at row #{@row}, asked for #{target})" if target < @row
        return if target == @row
        locs = @src.locations
        if locs
          j = locs.bsearch_index { |loc| loc.first_row_index > target }
          j = (j || locs.size) - 1
          if j > @page_idx
            @src.jump_to_page(j)
            @page = nil
            @bd = @br = nil
            @bi = 0
            @page_idx = j - 1
            @row = locs[j].first_row_index
            @started = true # pages listed in an OffsetIndex start at row boundaries
          end
        end
        skip(target - @row)
      end

      # Moves past the next +k+ rows without building their values
      def skip(k)
        return if k <= 0
        @repeated ? take_repeated(k, false) : take_flat(k, false)
        @row += k
        nil
      end

      # [definition_levels, repetition_levels, values] of the next +k+ rows. Levels are nil
      # when the column's max level is 0.
      def take(k)
        pieces = @repeated ? take_repeated(k) : take_flat(k)
        @row += k
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

      def take_flat(k, keep = true)
        pieces = []
        while k > 0
          load_page! while @page.nil? || @page.remaining.zero?
          t = @page.remaining
          t = k if k < t
          defs, = @page.read_levels(t)
          nv = defs ? defs.count(@max_def) : t
          if keep
            pieces << [defs, nil, values(nv)]
          else
            @page.skip_values(nv)
          end
          k -= t
        end
        pieces
      end

      # Collects entries until +k+ rows have started and the next row start (or the end of the
      # column) is reached. Values are read from a page before moving on to the next one.
      def take_repeated(k, keep = true)
        pieces = []
        rows = 0
        defs = @max_def.positive? ? [] : nil
        reps = []
        while true
          if @bi >= @br.to_a.size
            if @page&.remaining&.positive?
              @bd, @br = @page.read_levels(LOOKAHEAD)
              @bi = 0
            else
              flush(pieces, defs, reps, keep)
              defs = @max_def.positive? ? [] : nil
              reps = []
              break unless load_page
              next
            end
          end
          unless @started
            raise FormatError, "Column #{@path}: first page does not start at a row boundary" unless @br[@bi].zero?
            @started = true
          end
          br = @br
          i = @bi
          n = br.size
          done = false
          while i < n
            if br[i].zero?
              if rows == k
                done = true
                break
              end
              rows += 1
            end
            i += 1
          end
          if i > @bi
            reps.concat(br[@bi, i - @bi])
            defs&.concat(@bd[@bi, i - @bi])
            @bi = i
          end
          break if done
        end
        flush(pieces, defs, reps, keep)
        pieces
      end

      # Reads (or skips) the values belonging to the collected entries of the current page
      def flush(pieces, defs, reps, keep)
        return if reps.empty?
        nv = defs ? defs.count(@max_def) : reps.size
        if keep
          pieces << [defs, reps, values(nv)]
        else
          @page.skip_values(nv)
        end
      end

      def values(n)
        vals = @page.read_values(n)
        conv = @page.converter
        conv ? vals.map!(&conv) : vals
      end

      def load_page!
        return if load_page
        raise FormatError, "Column #{@path}: ran out of pages after #{@src.seen} of #{@src.total} values"
      end

      # Moves to the next data page; false at the end of the chunk
      def load_page
        @page = @src.next_stream or return false
        @page_idx += 1
        @bd = @br = nil
        @bi = 0
        true
      end
    end
  end
end

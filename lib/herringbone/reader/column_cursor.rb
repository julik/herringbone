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
      end

      # [definition_levels, repetition_levels, values] of the next +k+ rows. Levels are nil
      # when the column's max level is 0.
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
          load_page! while @page.nil? || @page.remaining.zero?
          t = @page.remaining
          t = k if k < t
          defs, = @page.read_levels(t)
          pieces << [defs, nil, values(defs ? defs.count(@max_def) : t)]
          k -= t
        end
        pieces
      end

      # Collects entries until +k+ rows have started and the next row start (or the end of the
      # column) is reached. Values are read from a page before moving on to the next one.
      def take_repeated(k)
        pieces = []
        rows = 0
        defs = @max_def.positive? ? [] : nil
        reps = []
        while true
          if @bi >= @br.to_a.size
            if @page && @page.remaining.positive?
              @bd, @br = @page.read_levels(LOOKAHEAD)
              @bi = 0
            else
              pieces << [defs, reps, values(defs ? defs.count(@max_def) : reps.size)] unless reps.empty?
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
        pieces << [defs, reps, values(defs ? defs.count(@max_def) : reps.size)] unless reps.empty?
        pieces
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
        @bd = @br = nil
        @bi = 0
        true
      end
    end
  end
end

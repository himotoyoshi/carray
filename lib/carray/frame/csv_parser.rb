# A small, self-contained CSV tokenizer for CAFrame.from_csv.
#
# It produces raw String cells and does no type inference — casting is a
# separate step. The tokenizer is tuned for the
# common shape of scientific / ETL CSV: records with no quote character take a
# single String#split fast path, and only quote-bearing records fall back to
# the field scanner. Quoted fields carry embedded separators, embedded newlines
# (multi-line records) and doubled-quote ("") escapes.
#
# Correctness choices:
#   * RFC 4180 spacing by default -- spaces are significant and preserved.
#     Pass +strip: true+ to trim unquoted fields (handy for numeric columns).
#   * An empty unquoted field is nil (missing); an empty quoted field ("") is
#     the empty String. Both cast to UNDEF for numeric columns (parse-mask).
#   * A UTF-8 BOM is stripped via the "bom|utf-8" read mode by default.
#   * Malformed input raises MalformedCSV naming the record number: a quote
#     inside an unquoted field, text after a closing quote, or a quoted field
#     still open at the end of input. A record continues onto the next line
#     only inside a quoted field.
#
# Two entry points share the Tokenizer:
#   * CSVParser.parse / parse_file -- whole-file parse into [headers, rows].
#   * CSVReader                    -- the block reading-control DSL used by
#                                     CAFrame.from_csv (header / skip / body /
#                                     column_names).

require "strscan"

class CAFrame
  # CSV tokenizer behind `CAFrame.from_csv`.  It produces raw String cells
  # and does no type inference — casting is a separate step.
  #
  # Records with no quote character take a `String#split` fast path; only
  # quote-bearing records fall back to the field scanner, which handles
  # embedded separators, embedded newlines and doubled-quote escapes.
  # Spacing follows RFC 4180 (significant and preserved) unless `strip:` is
  # given.  An empty unquoted field is `nil` (missing); an empty quoted field
  # is the empty String.
  module CSVParser
    module_function

    # Raised when the input cannot be tokenized, e.g. a quoted field that
    # never closes before end of input.
    class MalformedCSV < StandardError; end

    # Parse a file into [headers, rows]. +encoding+ is an IO open-mode encoding
    # string; the default strips a leading BOM and reads UTF-8.
    def parse_file(path, encoding: "bom|utf-8", **opts)
      File.open(path, "r:#{encoding}") { |io| parse(io, **opts) }
    end

    # Parse an IO (or anything answering +gets+). The first record supplies the
    # headers; the rest are data rows. Blank lines are skipped, including in a
    # one-column file (from_csv reads them there as missing cells).
    def parse(io, sep: ",", quote: '"', strip: false)
      tok = Tokenizer.new(sep, quote, strip)
      headers = nil
      rows    = []
      while (fields = tok.read(io))
        if headers.nil?
          headers = fields.map(&:to_s)
        else
          rows << fields
        end
      end
      [headers, rows]
    end

    # Splits records into fields. Regexps are compiled once and reused across
    # every record, so per-row cost stays low.
    class Tokenizer
      def initialize(sep, quote, strip)
        unless sep.is_a?(String) && !sep.empty?
          raise ArgumentError, "sep: must be a non-empty String (got #{sep.inspect})"
        end
        unless quote.is_a?(String) && quote.size == 1
          raise ArgumentError, "quote: must be one character (got #{quote.inspect})"
        end
        if sep.include?(quote)
          raise ArgumentError, "sep: #{sep.inspect} cannot contain the quote character"
        end
        @sep      = sep
        @quote    = quote
        @strip    = strip
        s = Regexp.escape(sep)
        q = Regexp.escape(quote)
        @sep_re   = /#{s}/
        @quote_re = /#{q}/
        # An unquoted field runs up to the separator, a quote or the end of
        # the record; a CR that does not end the record is part of the field.
        # A character class says "up to the separator" for a one-character
        # one; a longer one has to be matched as a whole, or "::" would end
        # the field at a single ":".
        @unquoted =
          if sep.size == 1
            /(?:[^#{s}#{q}\r\n]|\r(?!\n|\z))*/
          else
            /(?:(?!#{s})(?:[^#{q}\r\n]|\r(?!\n|\z)))*/
          end
        @inner    = /[^#{q}]*/
        @eol      = /\r?\n|\r\z/
        @recno    = 0
      end

      # Fields of the next record, or nil at EOF.  A blank line carries no
      # separator, so it cannot be a row of a file with more than one column
      # and is skipped as noise between records.  In a single-column file it
      # is the only spelling a missing single field has -- which is what
      # to_csv writes for a masked cell -- so the caller passes
      # +blank_is_row: true+ once the column count is known to be one, and
      # the empty record becomes a row of no fields for build_frame to pad.
      #
      # A line with no quote character is a whole record. One with a quote
      # goes to the scanner, which reads further lines only while a field
      # that opened with a quote is still open -- so a quote inside an
      # unquoted field is malformed rather than a reason to swallow the lines
      # after it, and a field of many lines is read once, not re-counted.
      def read(io, blank_is_row: false)
        loop do
          line = io.gets
          return nil if line.nil?
          @recno += 1
          return scan(line, io) if line.include?(@quote)
          rec = line.chomp
          next if rec.empty? && !blank_is_row
          return simple(rec)
        end
      end

      private def simple(rec)
        rec.split(@sep, -1).map do |cell|
          cell = cell.strip if @strip
          cell.empty? ? nil : cell
        end
      end

      # Fields of the record that starts on +line+, reading more lines from
      # +io+ while a quoted field is open. strip: skips spaces before a field,
      # so a quote after them still opens one.
      private def scan(line, io)
        sc = StringScanner.new(line)
        fields = []
        loop do
          sc.skip(/[ \t]+/) if @strip
          if sc.skip(@quote_re)
            fields << quoted_field(sc, io)
            # A closed quoted field ends at the separator or the end of the
            # record. Anything else there is malformed, and read on it would
            # drop the rest of the record without a word. strip: lets spaces
            # through, as it does around an unquoted field.
            sc.skip(/[ \t]+/) if @strip
            unless sc.eos? || sc.check(@sep_re) || sc.check(@eol)
              raise MalformedCSV,
                    "text #{sc.rest.chomp[0, 20].inspect} after the closing quote of " \
                    "field #{fields.size} in record #{@recno}"
            end
          else
            cell = sc.scan(@unquoted)
            if sc.check(@quote_re)
              raise MalformedCSV,
                    "a quote inside unquoted field #{fields.size + 1} in record " \
                    "#{@recno} (#{(cell + sc.rest.chomp)[0, 20].inspect}); a field " \
                    "holding a quote is written quoted, with the quote doubled"
            end
            cell = cell.strip if @strip
            fields << (cell.empty? ? nil : cell)
          end
          break unless sc.skip(@sep_re)
        end
        sc.skip(@eol)
        fields
      end

      # The rest of a field whose opening quote has been read, through its
      # closing quote. A doubled quote is a literal one; the end of the line
      # inside the field brings the next line in.
      private def quoted_field(sc, io)
        buf = +""
        loop do
          buf << sc.scan(@inner)
          if sc.eos?
            more = io.gets
            raise MalformedCSV, "unterminated quoted field in record #{@recno}" if more.nil?
            sc << more
            next
          end
          sc.skip(@quote_re)
          break unless sc.skip(@quote_re)
          buf << @quote
        end
        buf
      end
    end
  end

  # The block reading-control DSL for CAFrame.from_csv. A file
  # often has preamble lines, a units row, or no header at all; the block says,
  # in order, how to consume the stream:
  #
  #   CAFrame.from_csv(path) do
  #     skip 3          # drop 3 preamble lines
  #     header          # next record supplies the column names
  #     skip 1          # drop a units row
  #     body            # the rest are data rows
  #   end
  #
  #   CAFrame.from_csv(path) do   # headerless file
  #     column_names "date", "temp", "rh"
  #     body
  #   end
  #
  # The verbs are +skip+ / +header+ / +column_names+ / +body+; each returns a
  # value useful inline (header returns its fields) and the ordering is the
  # script. Without a block, from_csv runs the default +header+ then +body+.
  class CSVReader
    def initialize(io, sep: ",", quote: '"', strip: false)
      @io    = io
      @tok   = CSVParser::Tokenizer.new(sep, quote, strip)
      @names = nil
      @rows  = nil
    end

    # Drop +n+ raw lines (preamble, units, notes).
    def skip(n = 1)
      unless n.is_a?(Integer) && n >= 0
        raise ArgumentError, "skip takes a number of lines (got #{n.inspect})"
      end
      n.times { @io.gets }
      self
    end

    # Read one record. With no argument it becomes the column names; with a
    # name it is a secondary header (e.g. units) -- read, returned, not used as
    # names. Returns the record's fields either way.
    def header(name = nil)
      fields = @tok.read(@io)
      raise CSVParser::MalformedCSV, "header expected but input ended" if fields.nil?
      if name.nil?
        @names = fields.map(&:to_s)
      else
        (@named_headers ||= {})[name.to_s] = fields
      end
      fields
    end

    # Set the column names explicitly (headerless files).
    def column_names(*names)
      @names = names.flatten.map(&:to_s)
      self
    end

    # Consume the remaining records as data rows. A second body adds what is
    # left, which is nothing; it does not discard the rows already read.
    def body
      rows = (@rows ||= [])
      blank_is_row = @names && @names.size == 1
      while (fields = @tok.read(@io, blank_is_row: blank_is_row))
        rows << fields
      end
      self
    end

    # [names_or_nil, rows] for CAFrame.from_csv to build from. names is nil when
    # neither header nor column_names ran (positional names are generated).
    def result
      [@names, @rows || []]
    end
  end
end

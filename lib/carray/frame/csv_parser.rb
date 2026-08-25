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
#   * A parse error names the record number.
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
    # headers; the rest are data rows. Fully blank lines are skipped.
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

    # Read one logical record, joining continuation lines while a quoted field
    # is still open (an odd number of quote characters means unbalanced).
    def read_record(io, quote)
      line = io.gets
      return nil if line.nil?
      rec = line.dup
      while rec.count(quote).odd?
        more = io.gets
        raise MalformedCSV, "unterminated quoted field at end of input" if more.nil?
        rec << more
      end
      rec.chomp!
      rec
    end

    # Splits records into fields. Regexps are compiled once and reused across
    # every record, so per-row cost stays low.
    class Tokenizer
      def initialize(sep, quote, strip)
        @sep      = sep
        @quote    = quote
        @strip    = strip
        @sep_re   = /#{Regexp.escape(sep)}/
        @quote_re = /#{Regexp.escape(quote)}/
        @unquoted = /[^#{Regexp.escape(sep)}]*/
        @inner    = /[^#{Regexp.escape(quote)}]*/
        @recno    = 0
      end

      # Fields of the next non-blank record, or nil at EOF.
      def read(io)
        loop do
          rec = CSVParser.read_record(io, @quote)
          return nil if rec.nil?
          @recno += 1
          next if rec.empty?
          return rec.count(@quote).zero? ? simple(rec) : scan(rec)
        end
      end

      private def simple(rec)
        rec.split(@sep, -1).map do |cell|
          cell = cell.strip if @strip
          cell.empty? ? nil : cell
        end
      end

      private def scan(rec)
        sc = StringScanner.new(rec)
        fields = []
        loop do
          if sc.scan(@quote_re)
            buf = +""
            loop do
              buf << sc.scan(@inner)
              unless sc.scan(@quote_re)
                raise MalformedCSV, "unterminated quoted field in record #{@recno}"
              end
              if sc.scan(@quote_re) # doubled quote -> literal quote, field continues
                buf << @quote
              else
                break
              end
            end
            fields << buf
          else
            cell = sc.scan(@unquoted) || ""
            cell = cell.strip if @strip
            fields << (cell.empty? ? nil : cell)
          end
          break unless sc.scan(@sep_re)
        end
        fields
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

    # Consume the remaining records as data rows.
    def body
      rows = []
      while (fields = @tok.read(@io))
        rows << fields
      end
      @rows = rows
      self
    end

    # [names_or_nil, rows] for CAFrame.from_csv to build from. names is nil when
    # neither header nor column_names ran (positional names are generated).
    def result
      [@names, @rows || []]
    end
  end
end

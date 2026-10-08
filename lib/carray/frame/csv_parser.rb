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
#   * Malformed input raises MalformedCSV naming the file and the line: a
#     quote inside an unquoted field, text after a closing quote, a quoted
#     field still open at the end of input, or a record with more fields
#     than there are columns. A record continues onto the next line only
#     inside a quoted field.
#
# Two entry points share the Tokenizer:
#   * CSVParser.parse / parse_file -- whole-file parse into [headers, rows].
#   * CSVReader                    -- the block reading-control DSL used by
#                                     CAFrame.from_csv (header / skip / body /
#                                     column_names).

require "strscan"
require "stringio"

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

    # Raised when the input cannot be read as written. The message starts
    # with "path:line:" (or "line N:" for an IO with no path), the form an
    # editor or terminal jumps to; the record number follows when it is not
    # the line's, as after a quoted field of several lines or a +skip+.
    # +path+, +lineno+ and +record+ give the same for a program.
    class MalformedCSV < StandardError
      attr_accessor :path
      attr_reader :lineno, :record, :detail

      def initialize(detail = nil, lineno: nil, record: nil, path: nil)
        @detail = detail
        @lineno = lineno
        @record = record
        @path   = path
        super(detail)
      end

      def message
        return super if @detail.nil?
        where =
          if @path && @lineno then "#{@path}:#{@lineno}: "
          elsif @path         then "#{@path}: "
          elsif @lineno       then "line #{@lineno}: "
          else ""
          end
        tail = @record && @record != @lineno ? " (record #{@record})" : ""
        "#{where}#{@detail}#{tail}"
      end
    end

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
      attr_reader :sep, :quote, :strip

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
        @blank_re = /\A[ \t]*\z/
        @sep2     = sep * 2
        @qq       = quote * 2
        # A whole quoted field: its quotes closed, the ones inside doubled.
        @quoted_re = /\A#{q}(?:[^#{q}]|#{q}#{q})*#{q}\z/m
        @recno    = 0
        @lineno   = 0
        @record_line = 0
      end

      # The lines read so far, and the line the last record started on.
      attr_reader :lineno, :record_line

      # The next line of +io+, counted.
      def gets(io)
        line = io.gets
        @lineno += 1 if line
        line
      end

      # A MalformedCSV at +line+ of the current record.
      def malformed(detail, line = @record_line)
        MalformedCSV.new(detail, lineno: line, record: @recno)
      end

      # Fields of the next record, or nil at EOF.  A blank line -- empty, or
      # only spaces and tabs with no separator -- cannot be a row of a file
      # with more than one column and is skipped as noise between records.
      # In a single-column file it is a row: an empty line is the only
      # spelling a missing single field has, which is what to_csv writes for
      # a masked cell, and spaces are a value. So the caller passes
      # +blank_is_row: true+ once the column count is known to be one, and
      # the line becomes a row for build_frame to pad. +blank?+ says whether
      # the record just returned was such a line, for a caller that learns
      # the column count only after the body.
      #
      # A line with no quote character is a whole record. One with a quote
      # goes to the scanner, which reads further lines only while a field
      # that opened with a quote is still open -- so a quote inside an
      # unquoted field is malformed rather than a reason to swallow the lines
      # after it, and a field of many lines is read once, not re-counted.
      def read(io, blank_is_row: false, last_line: nil)
        loop do
          return nil if last_line && @lineno >= last_line
          line = gets(io)
          return nil if line.nil?
          @recno += 1
          @record_line = @lineno
          @blank = false
          if line.include?(@quote)
            return (!@strip && quoted_line(line)) || scan(line, io)
          end
          rec = line.chomp
          if rec.match?(@blank_re) && !rec.include?(@sep)
            next unless blank_is_row
            @blank = true
          end
          return simple(rec)
        end
      end

      def blank?
        @blank
      end

      # Count records and lines read elsewhere (the C reader), so the
      # numbers in an error stay those of the file.
      def advance(records, lines)
        @recno += records
        @lineno += lines
      end

      # An empty field lies at the start or the end of the record or between
      # two separators, so a record without one is the split as it stands.
      private def simple(rec)
        fields = rec.split(@sep, -1)
        if @strip
          fields.map! { |cell| cell = cell.strip; cell.empty? ? nil : cell }
        elsif rec.empty? || rec.start_with?(@sep) || rec.end_with?(@sep) || rec.include?(@sep2)
          fields.map! { |cell| cell.empty? ? nil : cell }
        end
        fields
      end

      # The fields of a one-line record holding quotes, read by splitting at
      # the separator: a quoted field is the pieces from one that opens with
      # a quote to the one that closes it (it may hold the separator). nil
      # when the record is not that simple -- a quoted field open at the end
      # of the line, a quote inside an unquoted field, text after a closing
      # quote -- for the scanner to read or to report.
      private def quoted_line(line)
        parts = line.chomp.split(@sep, -1)
        fields = []
        i = 0
        while i < parts.size
          part = parts[i]
          if part.start_with?(@quote)
            until part.match?(@quoted_re)
              i += 1
              return nil if i >= parts.size
              part = part + @sep + parts[i]
            end
            inner = part[1...-1]
            fields << (inner.include?(@quote) ? inner.gsub(@qq, @quote) : inner)
          elsif part.include?(@quote)
            return nil
          else
            fields << (part.empty? ? nil : part)
          end
          i += 1
        end
        fields
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
            fields << quoted_field(sc, io, fields.size + 1, line_at(sc))
            # A closed quoted field ends at the separator or the end of the
            # record. Anything else there is malformed, and read on it would
            # drop the rest of the record without a word. strip: lets spaces
            # through, as it does around an unquoted field.
            sc.skip(/[ \t]+/) if @strip
            unless sc.eos? || sc.check(@sep_re) || sc.check(@eol)
              raise malformed("text #{sc.rest.chomp[0, 20].inspect} after the closing quote " \
                              "of field #{fields.size}", line_at(sc))
            end
          else
            cell = sc.scan(@unquoted)
            if sc.check(@quote_re)
              raise malformed("a quote inside unquoted field #{fields.size + 1} " \
                              "(#{(cell + sc.rest.chomp)[0, 20].inspect}); a field holding " \
                              "a quote is written quoted, with the quote doubled", line_at(sc))
            end
            cell = cell.strip if @strip
            fields << (cell.empty? ? nil : cell)
          end
          break unless sc.skip(@sep_re)
        end
        sc.skip(@eol)
        fields
      end

      # The line of the file the scanner is at: the record's first line and
      # the line breaks it has passed in quoted fields.
      private def line_at(sc)
        @record_line + sc.string[0, sc.pos].count("\n")
      end

      # The rest of a field whose opening quote has been read, through its
      # closing quote. A doubled quote is a literal one; the end of the line
      # inside the field brings the next line in.
      private def quoted_field(sc, io, field_no, open_line)
        buf = +""
        loop do
          buf << sc.scan(@inner)
          if sc.eos?
            more = gets(io)
            if more.nil?
              raise malformed("quoted field #{field_no} opened here is never closed", open_line)
            end
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

  # The reading-control block for CAFrame.from_csv. A file often has
  # preamble lines, a units row, or no header at all; the block is given the
  # reader and says, in order, how to consume the stream:
  #
  #   CAFrame.from_csv(path) do |r|
  #     r.skip 3          # drop 3 preamble lines
  #     r.header          # next record supplies the column names
  #     r.skip 1          # drop a units row
  #     r.data            # the rest are data rows
  #   end
  #
  #   CAFrame.from_csv(path) { it.column_names "date", "temp", "rh"; it.data }
  #
  # The verbs are +skip+ / +header+ / +column_names+ / +data+; each returns a
  # value useful inline (header returns its fields) and the ordering is the
  # script. The reader is a parameter, not self, so a local variable named
  # +data+ or +header+ cannot stand in for the verb. Without a block,
  # from_csv reads by its header: / data: / column_names: (see +layout+).
  class CSVReader
    def initialize(io, sep: ",", quote: '"', strip: false)
      @io    = io
      @path  = io.path if io.respond_to?(:path)
      @tok   = CSVParser::Tokenizer.new(sep, quote, strip)
      @names = nil
      @rows  = nil
    end

    # Drop +n+ raw lines (preamble, units, notes).
    def skip(n = 1)
      unless n.is_a?(Integer) && n >= 0
        raise ArgumentError, "skip takes a number of lines (got #{n.inspect})"
      end
      n.times { @tok.gets(@io) }
      self
    end

    # Read one record. With no argument it becomes the column names; with a
    # name it is a secondary header (e.g. units) -- read, returned, not used as
    # names. Returns the record's fields either way.
    def header(name = nil)
      fields = @tok.read(@io)
      if fields.nil?
        raise CSVParser::MalformedCSV.new("header expected but input ended",
                                          lineno: @tok.lineno + 1)
      end
      if name.nil?
        @names = fields.map(&:to_s)
        @header_line = @tok.record_line
        @names_to_check = nil
      else
        (@named_headers ||= {})[name.to_s] = fields
      end
      fields
    end

    # Set the column names explicitly: for a file with no header, or in
    # place of the names a header gave. Their number has to be the file's
    # number of columns -- the header's, or else that of the first record
    # of the data -- or a name would go to no column, or a column without
    # one.
    def column_names(*names)
      names = names.flatten.map(&:to_s)
      if @header_line
        check_column_names(names, @names.size, @header_line)
      else
        @names_to_check = names
      end
      @names = names
      self
    end

    private def check_column_names(names, ncol, line)
      return if names.size == ncol
      raise ArgumentError, "from_csv: column_names: gives #{names.size} " \
                           "name#{names.size == 1 ? '' : 's'} for the #{ncol} columns of line #{line}"
    end

    # Consume the remaining records as data rows. A second data adds what is
    # left, which is nothing; it does not discard the rows already read.
    #
    # Without names the column count is known only once every row is read,
    # so blank lines are kept and marked, and +result+ drops them unless the
    # file turns out to have one column -- the same rows a header would have
    # given.
    #
    # Without strip:, the rest of the input is read in C (CArray.__csv_read_body_as_string_cells__)
    # straight into the table, with the column count of the names, or of the
    # first record when there are none. When C declines -- text not in
    # UTF-8, a record it does not take, or one longer than the first in a
    # file without names -- the text from there on is read here, which pads
    # the earlier rows or reports what is wrong.
    def data
      read_data(nil)
    end

    # The header: / data: / column_names: of from_csv, as the verbs above.
    # They index the lines of the file from 0, as File.readlines does (an
    # error names a line from 1, as an editor does). header: defaults to 0,
    # or to none (false) when column_names: is given; data: is the first line
    # of the data or a Range of lines, by default from the line after the
    # header. A record that starts within data: is read whole.
    def layout(header: nil, data: nil, column_names: nil)
      header = column_names ? false : 0 if header.nil?
      unless header == false || (header.is_a?(Integer) && header >= 0)
        raise ArgumentError, "from_csv: header: takes the index of a line, from 0, " \
                             "or false (got #{header.inspect})"
      end
      first, last = CSVReader.data_lines(data)
      if header
        skip(header - @tok.lineno) if header > @tok.lineno
        self.header
      end
      column_names(*column_names) if column_names
      first ||= @tok.lineno
      if first < @tok.lineno
        raise ArgumentError, "from_csv: data: #{first} does not come after header: #{header}"
      end
      skip(first - @tok.lineno)
      read_data(last && last + 1)
    end

    # [first, last] line indexes of a data: setting, nil for an end left open.
    def self.data_lines(spec)
      first, last =
        case spec
        when nil     then [nil, nil]
        when Integer then [spec, nil]
        when Range
          e = spec.end
          e -= 1 if e.is_a?(Integer) && spec.exclude_end?
          [spec.begin, e]
        else
          raise ArgumentError, "from_csv: data: takes the index of a line or a Range of " \
                               "them, from 0 (got #{spec.inspect})"
        end
      [first, last].each do |n|
        next if n.nil? || (n.is_a?(Integer) && n >= 0)
        raise ArgumentError, "from_csv: data: lines are indexed from 0 (got #{spec.inspect})"
      end
      if first && last && last < first
        raise ArgumentError, "from_csv: data: #{spec.inspect} ends before it starts"
      end
      [first, last]
    end

    # The records from here through those starting on +last+ (nil: the end).
    private def read_data(last)
      body_in_c(last) if @rows.nil? && !@tok.strip && @io.respond_to?(:read)
      return self if @table
      rows = (@rows ||= [])
      @blank_rows ||= []
      blank_is_row = @names.nil? || @names.size == 1
      ncol = @names&.size
      while (fields = @tok.read(@io, blank_is_row: blank_is_row, last_line: last))
        if @names_to_check && !@tok.blank?
          check_column_names(@names_to_check, fields.size, @tok.record_line)
          @names_to_check = nil
        end
        if ncol && fields.size > ncol
          raise @tok.malformed("#{fields.size} fields, but there are #{ncol} columns")
        end
        @blank_rows << rows.size if @names.nil? && @tok.blank?
        rows << fields
      end
      self
    end

    # Run the block, naming the file in a MalformedCSV it raises.
    def reporting
      yield
    rescue CSVParser::MalformedCSV => e
      e.path ||= @path
      raise
    end

    # The text C reads at a time when the column count is known; a chunk
    # ends at a line end, and not inside a quoted field.
    CHUNK_BYTES = 1 << 22

    # With names, the input goes to C a chunk at a time, so the text is not
    # held whole beside its cells. Without them, the column count and which
    # blank lines are rows are known only at the end, so it goes in whole;
    # so it does when the IO transcodes, since read(length) does not.
    private def body_in_c(last = nil, chunk_bytes = CHUNK_BYTES)
      chunked = last.nil? && @names && @io.respond_to?(:external_encoding) &&
                @io.internal_encoding.nil?
      # Names that have to agree with the first record leave its column
      # count to C, to be checked against them.
      ncol = @names && !@names_to_check ? @names.size : 0
      cells = []
      loop do
        text = if chunked then next_chunk(chunk_bytes)
               elsif last then lines_through(last)
               else @io.read || ""
               end
        break if text.nil?
        n, flat, records = CArray.__csv_read_body_as_string_cells__(text, @tok.sep, @tok.quote, ncol)
        unless flat
          # This chunk and the rest are read by the Ruby tokenizer, after the
          # rows read so far.
          @rows = ncol > 0 ? cells.each_slice(ncol).to_a : []
          @io = StringIO.new(chunked ? text + (@io.read || "") : text)
          return
        end
        if @names_to_check
          check_column_names(@names_to_check, n, @tok.lineno + first_record_line(text))
          @names_to_check = nil
        end
        ncol = n
        cells.concat(flat)
        @tok.advance(records, text.count("\n") + (text.empty? || text.end_with?("\n") ? 0 : 1))
        break unless chunked
      end
      if ncol == 0                    # no record, for the names to be checked against
        @rows = []
        return
      end
      @table = CArray.object(cells.size / ncol, ncol) { cells }
      @rows = []
    end

    # The line, from 1 within +text+, of its first record: past the blank
    # lines before it, as C reads them.
    private def first_record_line(text)
      line = 1
      text.each_line do |l|
        rec = l.chomp
        break unless rec.match?(/\A[ \t]*\z/) && !rec.include?(@tok.sep)
        line += 1
      end
      line
    end

    # The lines through +last+, read on past any quoted field still open.
    private def lines_through(last)
      buf = +""
      (last - @tok.lineno).times do
        line = @io.gets or break
        buf << line
      end
      while buf.count(@tok.quote).odd? && (more = @io.gets)
        buf << more
      end
      buf
    end

    # The next chunk_bytes of the input, read on to the end of its line and
    # past any quoted field still open, in the IO's encoding; nil at EOF.
    private def next_chunk(chunk_bytes)
      buf = @io.read(chunk_bytes)
      return nil if buf.nil?
      buf.force_encoding(@io.external_encoding || Encoding.default_external)
      if !buf.end_with?("\n") && (rest = @io.gets)
        buf << rest
      end
      while buf.count(@tok.quote).odd? && (more = @io.gets)
        buf << more
      end
      buf
    end

    # [names_or_nil, rows] for CAFrame.from_csv to build from. names is nil when
    # neither header nor column_names ran (positional names are generated).
    def result
      return [@names, @table] if @table
      rows = @rows || []
      if @names.nil? && @blank_rows && !@blank_rows.empty? &&
         rows.map(&:size).max != 1
        drop = @blank_rows.to_h { |i| [i, true] }
        rows = rows.reject.with_index { |_, i| drop[i] }
      end
      [@names, rows]
    end
  end
end

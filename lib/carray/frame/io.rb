# CAFrame CSV input/output (memo §11.2, §6-2).

require "carray/frame/csv_parser"

class CAFrame
  # Read a CSV into a frame. The header row supplies column names (Strings,
  # §3.7); every column is built raw as an object CArray of the cell strings
  # (§4.2 -- read and arrange only, no type-inference engine). Casting is a
  # separate step: pass +types:+ ({ "temp" => :float64 }, or the array-key /
  # reverse forms of +cast+) to cast named columns on load, or call +cast+
  # later. Broken cells fail to_type and become UNDEF automatically
  # (parse-mask, §6-2).
  #
  # Parsing uses the built-in fast tokenizer (CSVParser). Options:
  #   sep:      field separator (default ",")
  #   quote:    quote character (default '"')
  #   strip:    trim spaces from unquoted fields (default false, RFC spacing)
  #   +encoding+: IO open-mode encoding (default "bom|utf-8", strips a BOM)
  #   parser:   a callable path -> [headers, rows] to inject another parser
  #             (e.g. the stdlib +csv+, or a typed-table source); when given,
  #             sep/quote/strip/encoding and any block are that parser's concern.
  #
  # A block gives reading control for files with preamble lines, a units row,
  # or no header (memo §11.2), using +skip+ / +header+ / +column_names+ /
  # +body+ (see CSVReader). Without a block the default is +header+ then +body+.
  #
  #   CAFrame.from_csv("obs.csv") do
  #     skip 2; header; skip 1; body
  #   end
  #
  # Columns are handed to the frame as CABlock views over one backing object
  # array (§3.6 view-by-default); casting a column materializes it, and +copy+
  # gives an independent frame.
  def self.from_csv(path, types: nil,
                    sep: ",", quote: '"', strip: false,
                    encoding: "bom|utf-8", parser: nil, &block)
    names, rows =
      if parser
        parser.call(path)
      else
        File.open(path, "r:#{encoding}") do |io|
          reader = CSVReader.new(io, sep: sep, quote: quote, strip: strip)
          if block
            block.arity == 1 ? block.call(reader) : reader.instance_exec(&block)
          else
            reader.header
            reader.body
          end
          reader.result
        end
      end

    frame = build_frame(names, rows)
    frame.cast(types) if types
    frame
  end

  # Build a frame from parsed [names, rows]. When names is nil (headerless and
  # no column_names) positional names "c0".."cN" are generated from the widest
  # row. Rows are squared off to the column count (short rows padded with nil,
  # over-long rows raise), one 2-D object array is bulk-filled, and each column
  # is a view into it (§3.6).
  # Write the frame as CSV. CSV is a flat table of scalar cells, so this is the
  # text form of the same all-scalar subset +to_ca+ requires (§11.9): every
  # column must be 1-D. Unlike +to_ca+ it does not promote to a common data type --
  # each column is formatted to text independently, so mixed data types (numbers,
  # strings, datetime / categorical Faces) sit side by side. An N-D column has
  # no flat CSV cell and raises; export it per column, or use +to_records+ +
  # JSON for the structured shape (memo §11.9, the N-D escape).
  #
  # With +path+, writes the file and returns self; without it, returns the CSV
  # String. The index (if any) is written as the first column under +axis_name+
  # unless +index: false+. A masked cell (UNDEF) becomes an empty field, which
  # +from_csv+ reads back as UNDEF (parse-mask, §6-2) -- so mask round-trips. A
  # genuine empty string is written quoted (+""+) to stay distinct from missing,
  # matching the tokenizer's own unquoted-empty vs quoted-empty distinction.
  #
  #   df.to_csv("out.csv")          # write file
  #   csv = df.to_csv               # get a String
  #
  # Options: +sep+ / +quote+ mirror +from_csv+; +header+ writes the name row
  # (default true); +index+ writes the index column (default true).
  def to_csv(path = nil, sep: ",", quote: '"', header: true, index: true)
    nd = @columns.find { |_, c| c.ndim != 1 }
    if nd
      raise ArgumentError,
            "to_csv needs all-scalar (1-D) columns; #{nd.first.inspect} is " \
            "#{nd.last.ndim}-D — export it per column or via to_records + JSON"
    end

    names     = []
    formatted = []
    if index && @index
      names     << @axis_name
      formatted << format_csv_column(@index)
    end
    @columns.each do |name, col|
      names     << name
      formatted << format_csv_column(col)
    end

    out = +""
    if header
      out << names.map { |t| quote_csv_field(t, sep, quote) }.join(sep) << "\n"
    end
    @nrow.times do |i|
      out << formatted.map { |fcol| quote_csv_field(fcol[i], sep, quote) }.join(sep) << "\n"
    end

    if path
      File.write(path, out)
      self
    else
      out
    end
  end

  # Render the frame as an aligned text table for reading:
  #
  #   puts df.to_table
  #
  #   time        temp  station
  #   ----------  ----  -------
  #   2026-01-01   1.5  Tokyo
  #   2026-01-02     _  Osaka
  #
  # This is the display counterpart of +to_csv+ and shares none of its
  # constraints: it is text meant to be looked at, not read back. Numeric
  # columns are right-aligned, everything else left-aligned; a masked cell
  # shows as +_+, the same marker CArray's own inspect uses. An N-D column
  # (which +to_csv+ rejects, having no flat cell) shows each row's slice as
  # an Array literal.
  #
  # Float cells are rounded to +precision+ decimal places for display only
  # (default 6); +precision: nil+ prints them at full precision, which is
  # faithful but lets one long value set the column width.
  #
  # Long frames are truncated in the middle: +rows+ caps how many rows are
  # printed (default 20, split evenly around an ellipsis row), and
  # +rows: nil+ prints every row. +index: false+ drops the index column.
  def to_table(rows: 20, index: true, precision: 6)
    head = rows && (rows + 1) / 2
    render_table(head: head, tail: rows && rows - head,
                 index: index, precision: precision, footer: true)
  end

  # +to_s+ is the whole frame, +inspect+ the middle-elided one -- so +puts df+
  # dumps everything and +p df+ stays a screenful. +inspect+ leads with the
  # same summary line it always had (nrow, variable data types, index), so the
  # table under it needs no row-count footer.
  def to_s
    to_table(rows: nil)
  end

  def inspect
    parts = @columns.map { |k, v| "#{k}:#{v.data_type}#{v.ndim > 1 ? v.shape[1..].inspect : ''}" }
    idx = @index ? " index=#{@axis_name.inspect}" : ""
    head = "#<CAFrame nrow=#{@nrow} vars=[#{parts.join(', ')}]#{idx}>"
    return head if @columns.empty?
    head + "\n" + render_table(head: 8, tail: 2, index: true, precision: 6,
                               footer: false)
  end

  private def render_table(head:, tail:, index:, precision:, footer:)
    names   = []
    columns = []
    aligns  = []

    if index && @index
      names   << @axis_name
      columns << @index
      aligns  << (@index.numeric? ? :right : :left)
    end
    @columns.each do |name, col|
      names   << name
      columns << col
      aligns  << (col.ndim == 1 && col.numeric? ? :right : :left)
    end
    return "" if names.empty?

    positions = table_row_positions(head, tail)
    body = positions.map do |i|
      if i.nil?
        Array.new(columns.size, ":") # vertical ellipsis for the elided middle
      else
        columns.map { |col| format_table_cell(col, i, precision) }
      end
    end

    widths = names.each_with_index.map do |name, j|
      [display_width(name), *body.map { |cells| display_width(cells[j]) }].max
    end

    out = +""
    out << table_row(names, widths, aligns) << "\n"
    out << table_row(widths.map { |w| "-" * w }, widths, aligns) << "\n"
    body.each { |cells| out << table_row(cells, widths, aligns) << "\n" }
    if footer && positions.size - positions.count(nil) < @nrow
      out << "(#{plural(@nrow, 'row')}, #{plural(@columns.size, 'variable')})\n"
    end
    out
  end

  # Row indices to print, with nil marking the elided middle. A nil head means
  # no cap; a frame that already fits in head + tail is listed whole.
  private def table_row_positions(head, tail)
    return (0...@nrow).to_a if head.nil? || @nrow <= head + tail
    (0...head).to_a + [nil] + ((@nrow - tail)...@nrow).to_a
  end

  private def table_row(cells, widths, aligns)
    line = cells.each_with_index.map do |text, j|
      pad = " " * (widths[j] - display_width(text))
      aligns[j] == :right ? pad + text : text + pad
    end.join("  ")
    line.rstrip
  end

  # Column widths are counted in terminal cells, not characters: a CJK
  # ideograph, kana, or full-width form occupies two cells, so counting
  # characters would leave every column holding such a name ragged. The
  # ranges below are the East Asian Wide / Fullwidth blocks; a combining
  # mark takes no cell of its own.
  WIDE_CHAR_RANGES = [
    0x1100..0x115F, 0x2E80..0x303E, 0x3041..0x33FF, 0x3400..0x4DBF,
    0x4E00..0x9FFF, 0xA000..0xA4CF, 0xA960..0xA97F, 0xAC00..0xD7A3,
    0xF900..0xFAFF, 0xFE10..0xFE19, 0xFE30..0xFE6F, 0xFF00..0xFF60,
    0xFFE0..0xFFE6, 0x1F300..0x1F64F, 0x1F900..0x1F9FF, 0x20000..0x3FFFD,
  ].freeze
  private_constant :WIDE_CHAR_RANGES

  COMBINING_RANGES = [0x0300..0x036F, 0x1AB0..0x1AFF, 0x20D0..0x20F0].freeze
  private_constant :COMBINING_RANGES

  private def display_width(text)
    text.each_char.sum do |ch|
      cp = ch.ord
      if COMBINING_RANGES.any? { |r| r.cover?(cp) }
        0
      elsif WIDE_CHAR_RANGES.any? { |r| r.cover?(cp) }
        2
      else
        1
      end
    end
  end

  private def plural(n, noun)
    "#{n} #{noun}#{n == 1 ? '' : 's'}"
  end

  private def format_table_cell(col, i, precision)
    e = elem_at(col, i)
    if UNDEF.equal?(e) || e.nil?
      "_"
    elsif e.is_a?(Float) && precision
      # Display rounding only: a full-precision float (141.67833333333334)
      # sets the column width for every other row and makes the table hard
      # to read. precision: nil prints the value as Ruby renders it.
      e.round(precision).to_s
    elsif e.is_a?(CArray)
      e.to_a.inspect
    elsif e.is_a?(String)
      e
    elsif e.respond_to?(:iso8601)
      e.iso8601
    else
      e.to_s
    end
  end

  private def format_csv_column(col)
    col.to_a.map do |e|
      if UNDEF.equal?(e) || e.nil?
        nil
      elsif e.is_a?(String)
        e
      elsif e.respond_to?(:iso8601)
        e.iso8601
      else
        e.to_s
      end
    end
  end

  private def quote_csv_field(text, sep, quote)
    return "" if text.nil?
    if text.empty? || text.include?(sep) || text.include?(quote) ||
       text.include?("\n") || text.include?("\r")
      quote + text.gsub(quote, quote * 2) + quote
    else
      text
    end
  end

  def self.build_frame(names, rows)
    ncol  = names ? names.size : (rows.map(&:size).max || 0)
    names ||= Array.new(ncol) { |j| "c#{j}" }

    cols = {}
    if rows.empty?
      names.each { |name| cols[name] = CArray.object(0) }
      return new(cols)
    end
    rows.each_with_index do |r, i|
      if r.size < ncol
        r.concat(Array.new(ncol - r.size))
      elsif r.size > ncol
        raise ArgumentError,
              "row #{i + 1} has #{r.size} fields, expected #{ncol}"
      end
    end
    table = CArray.object(rows.size, ncol) { rows }
    names.each_with_index { |name, j| cols[name] = table[nil, j] }
    new(cols)
  end
  private_class_method :build_frame
end

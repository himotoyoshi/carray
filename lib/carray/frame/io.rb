# CAFrame CSV input/output (memo §11.2, §6-2).

require "carray/frame/csv_parser"

class CAFrame
  # Read a CSV into a frame. The header row supplies column names (Strings,
  # §3.7); every column is built raw as a CAString of the cell strings, all
  # over one object array (§4.2). Casting is a separate step: pass +types:+ ({ "temp" => :float64 },
  # or the array-key form of +cast+) to cast named columns on load,
  # +types: :infer+ to cast the columns +infer_types+ finds to be numbers or
  # times, or call +cast+ later. Broken cells become UNDEF automatically
  # (parse-mask, §6-2).
  #
  # +:default+ in the map sets the columns the map does not name, so the
  # two combine in one call; a named column's entry replaces the default,
  # and nil leaves the column as text:
  #
  #   CAFrame.from_csv("obs.csv", types: { default: :infer, "code" => :int32, "id" => nil })
  #   CAFrame.from_csv("obs.csv", types: { default: :float64, "station" => nil })
  #
  # +source+ is a path, or an open IO -- anything answering +gets+, which a
  # StringIO is. So CSV that is already in memory does not have to go to a
  # temporary file first:
  #
  #   CAFrame.from_csv("obs.csv")                    # a path
  #   CAFrame.from_csv(StringIO.new(body))           # text already in hand
  #   File.open("obs.csv") { |io| CAFrame.from_csv(io) }
  #
  # A String is always read as a path, never as CSV text: guessing between the
  # two by looking for a newline is the kind of guess that is right until it is
  # not, and StringIO says which one you meant in six characters. An IO is read
  # from where it is and left open -- the caller opened it and closes it.
  #
  # Parsing uses the built-in fast tokenizer (CSVParser). Options:
  #   sep:      field separator (default ",")
  #   quote:    quote character (default '"')
  #   strip:    trim spaces from unquoted fields (default false, RFC spacing)
  #   +encoding+: open-mode encoding for a path (default "bom|utf-8", strips a
  #             BOM). It has nothing to open when +source+ is an IO, so there
  #             the IO's own encoding governs and a BOM is the caller's. To
  #             read a file in another encoding, name it and the one to
  #             transcode to: "CP932:UTF-8" for a CSV written by Excel in
  #             Japanese.
  #   parser:   a callable source -> [headers, rows] to inject another parser
  #             (e.g. the stdlib +csv+, or a typed-table source); when given,
  #             sep/quote/strip/encoding and any block are that parser's concern.
  #   on_error: what a +types:+ cast does with a cell that does not read
  #             (:mask default, :warn, :raise); see +cast+.
  #
  # Where the header and the data are is given by the index of the line,
  # from 0, as in File.readlines (an error names the line from 1, as an
  # editor numbers it):
  #   header:   the line of the column names (default 0), or false for none
  #   data:     the first line of the data (default the line after the
  #             header), or a Range of lines; a record that starts in it is
  #             read whole
  #   column_names: the names, for a file with none or to replace them; the
  #             header then defaults to none
  #
  #   CAFrame.from_csv("obs.csv", header: 2)            # a title above
  #   CAFrame.from_csv("obs.csv", header: 0, data: 3)   # units on lines 1-2
  #   CAFrame.from_csv("big.csv", data: 1..100)         # the first 100 lines
  #   CAFrame.from_csv("raw.csv", column_names: %w[date temp rh])
  #
  # A block, given the reader, reads in any other order with +skip+ /
  # +header+ / +header(name)+ / +column_names+ / +data+ (see CSVReader):
  #
  #   CAFrame.from_csv("obs.csv") { |r| r.skip 2; r.header; r.skip 1; r.data }
  #
  # A missing field -- an unquoted empty one, or a cell a short row never
  # reached -- is UNDEF in the frame, whether or not the column is cast by
  # +types:+. A quoted empty field ("") is the empty string, which is a value.
  # So the mask +to_csv+ writes comes back as a mask.
  #
  # Files that spell "missing" some other way say so with +missing:+. A field
  # whose text is one of the given tokens is UNDEF too, before +types:+
  # casts, so a -999 sentinel never reaches the column as a number:
  #
  #   CAFrame.from_csv("obs.csv", missing: ["-999", "///"])        # every column
  #   CAFrame.from_csv("obs.csv", missing: { "temp" => "-999" })   # one column
  #   CAFrame.from_csv("obs.csv", missing: { default: "-999", "id" => [] })
  #
  # Tokens are Strings and are compared with the field's text as read (after
  # +strip:+, quoted or not), so "-999" does not match "-999.0". In a Hash,
  # +:default+ gives the tokens for every column and a column name gives that
  # column's own, which replace the default ([] or "" for none); without
  # +:default+ the columns it does not name keep only the empty field. As in
  # +to_csv+, "" means the empty field, so a quoted "" is still a value.
  #
  # Columns are handed to the frame as CABlock views over one backing object
  # array (§3.6 view-by-default); casting a column materializes it, and +copy+
  # gives an independent frame.
  def self.from_csv(source, types: nil, on_error: :mask, missing: nil,
                    header: nil, data: nil, column_names: nil,
                    sep: ",", quote: '"', strip: false,
                    encoding: "bom|utf-8", parser: nil, &block)
    layout = { header: header, data: data, column_names: column_names }.compact
    if block && !layout.empty?
      raise ArgumentError, "from_csv: give #{layout.keys.map { |k| "#{k}:" }.join(', ')} " \
                           "or a reading block, not both"
    end
    if block && block.arity != 1
      raise ArgumentError, "from_csv: the reading block takes the reader as its " \
                           "parameter, as in from_csv(path) { |r| r.skip 2; r.header; r.data }"
    end
    missing = missing_tokens(missing) if missing
    names, rows =
      if parser
        parser.call(source)
      elsif source.respond_to?(:gets)
        with_encoding_hint("open the IO in the file's encoding, as in " \
                           "File.open(path, \"r:<file encoding>:UTF-8\")") do
          read_csv(source, sep: sep, quote: quote, strip: strip, layout: layout, &block)
        end
      else
        with_encoding_hint("it was opened as #{encoding.inspect}; pass the " \
                           "file's encoding, as in " \
                           "encoding: \"<file encoding>:UTF-8\"") do
          File.open(source, "r:#{encoding}") do |io|
            read_csv(io, sep: sep, quote: quote, strip: strip, layout: layout, &block)
          end
        end
      end

    frame = build_frame(names, rows)
    mask_missing_tokens(frame, missing) if missing
    cast_on_load(frame, types, on_error)
    frame
  end

  # Split a +missing:+ argument, as from_csv and to_csv both take it, into the
  # setting for every column and a Hash of per-column settings that replace
  # it. A Hash says :default for every column and a column name for one;
  # column names are Strings, so the Symbol cannot collide with one. A
  # setting that is not a Hash is the default.
  def self.split_missing(missing, verb)
    return [missing, {}] unless missing.is_a?(Hash)
    default = nil
    per_column = {}
    missing.each do |key, value|
      case key
      when :default then default = value
      when String   then per_column[key] = value
      else
        raise ArgumentError,
              "#{verb}: missing: takes column names (Strings) and :default " \
              "as keys (got #{key.inspect})"
      end
    end
    [default, per_column]
  end

  # The read side of missing:, checked before the file is read: each setting
  # becomes an Array of token Strings.
  def self.missing_tokens(missing)
    default, per_column = split_missing(missing, "from_csv")
    tokens = lambda do |value|
      list = Array(value)
      bad = list.reject { |t| t.is_a?(String) }
      unless bad.empty?
        raise ArgumentError,
              "missing: tokens are matched against a field's text, so give them " \
              "as Strings (#{bad.map { |t| t.to_s.inspect }.join(', ')}, not " \
              "#{bad.map(&:inspect).join(', ')})"
      end
      # "" is the empty field, which is missing already; as on the write side
      # it adds nothing, so a quoted "" stays the empty string.
      list.reject(&:empty?)
    end
    [tokens.(default), per_column.transform_values(&tokens)]
  end

  def self.mask_missing_tokens(frame, missing)
    default, per_column = missing
    per_column.each_key { |name| frame[name] }    # KeyError for a name the file lacks
    frame.variable_names.each do |name|
      col = frame[name]
      per_column.fetch(name, default).each { |t| col[:eq, t] = UNDEF }
    end
  end

  private_class_method :split_missing, :missing_tokens, :mask_missing_tokens

  # Drive the reading-control DSL over one open IO and hand back
  # [names, rows]. Shared by the path and the IO source, so the two cannot
  # come to read a file differently.
  def self.read_csv (io, sep:, quote:, strip:, layout:, &block)
    reader = CSVReader.new(io, sep: sep, quote: quote, strip: strip)
    reader.reporting do
      block ? block.call(reader) : reader.layout(**layout)
    end
    reader.result
  end

  private_class_method :read_csv

  # The types: of from_csv / from_records: a map for cast, or :infer to
  # cast what infer_types finds.
  #
  # A map may say +:default+ for the columns it does not name: :infer casts
  # the ones infer_types finds among them, a type casts all of them. A named
  # column takes its own entry, which replaces the default; nil leaves it as
  # it was read.
  def self.cast_on_load(frame, types, on_error)
    return if types.nil?
    types = { default: :infer } if types == :infer
    unless types.is_a?(Hash)
      raise ArgumentError, "types: takes a map of column types or :infer " \
                           "(got #{types.inspect})"
    end
    default = nil
    named = {}
    types.each do |key, type|
      if key == :default
        default = type
      elsif key.is_a?(Symbol)
        raise ArgumentError, "types: takes column names (Strings) and :default " \
                             "as keys (got #{key.inspect})"
      else
        Array(key).each { |name| named[name.to_s] = type }
      end
    end
    named.each_key { |name| frame[name] }    # KeyError for a column that is not there

    rest = frame.variable_names - named.keys
    map =
      case default
      when nil    then {}
      when :infer then rest.empty? ? {} : frame.select(*rest).infer_types
      else             rest.to_h { |name| [name, default] }
      end
    map.merge!(named.compact)
    frame.cast(map, on_error: on_error) unless map.empty?
  end

  private_class_method :cast_on_load

  # Re-raise a failure to decode the input with a line saying how to name the
  # file's encoding. The error and its class are kept; only the message grows.
  # Which encoding the file is in cannot be told from its bytes, so the hint
  # names the option, not a value.
  def self.with_encoding_hint(hint)
    yield
  rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError,
         Encoding::CompatibilityError, ArgumentError => e
    raise if e.is_a?(ArgumentError) && !e.message.include?("invalid byte sequence")
    if e.is_a?(Encoding::CompatibilityError)
      # The text decoded; the separator or quote is in another encoding.
      raise e.class, "#{e.message} -- sep: and quote: are matched against the " \
                     "text as read, so read the file transcoded to UTF-8, as in " \
                     "encoding: \"<file encoding>:UTF-8\"", e.backtrace
    end
    raise e.class, "#{e.message} -- the CSV is not in the encoding it was " \
                   "read as: #{hint}", e.backtrace
  end

  private_class_method :with_encoding_hint

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
  # (default true); +index+ writes the index column (default true);
  # +encoding+ transcodes the text before it is written or returned (default
  # nil leaves it as built, UTF-8). A character the encoding cannot hold
  # raises Encoding::UndefinedConversionError rather than being dropped. A
  # String cell in another encoding is transcoded to UTF-8; one with bytes
  # that are not valid in it, or with no encoding (ASCII-8BIT), raises. Each
  # names the row and the column of the cell.
  #
  #   df.to_csv("out.csv", encoding: "CP932")   # for Excel in Japanese
  #
  # +missing:+ writes a masked cell as that String instead of an empty field,
  # for a reader that expects a sentinel; +from_csv(missing:)+ with the same
  # String reads it back as UNDEF. A Hash sets it per column the way
  # +from_csv+ does: +:default+ for every column, and a column name (or the
  # index's axis name) for one, replacing the default; "" is the empty field.
  # A cell whose value would be written as the same text raises, since the
  # file could not tell the two apart.
  #
  #   df.to_csv("out.csv", missing: "-999")
  #   df.to_csv("out.csv", missing: { default: "-999", "comment" => "" })
  def to_csv(path = nil, sep: ",", quote: '"', header: true, index: true,
             encoding: nil, missing: nil)
    default, per_column = CAFrame.send(:split_missing, missing, "to_csv")
    [default, *per_column.values].each do |text|
      next if text.nil? || text.is_a?(String)
      raise ArgumentError, "to_csv: missing: is the String written for a masked " \
                           "cell (got #{text.inspect})"
    end
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
    unknown = per_column.keys - names
    raise KeyError, "to_csv: missing: names no column #{unknown.first.inspect}" unless unknown.empty?
    formatted.each_with_index do |fcol, j|
      token = per_column.fetch(names[j], default)
      next if token.nil? || token.empty?        # the empty field, as without missing:
      i = fcol.index(token)
      if i
        raise ArgumentError,
              "to_csv: row #{i} of #{names[j].inspect} is written as " \
              "#{token.inspect}, the text given for a masked cell"
      end
      fcol.map! { |text| text.nil? ? token : text }
    end

    out = begin
      csv_text(names, formatted, header, sep, quote)
    rescue Encoding::CompatibilityError
      nil
    end
    # A cell in another encoding, or with bytes that are not text, is found
    # and named here, after the text was built in one pass, so a frame of
    # UTF-8 text pays nothing for the check.
    unless out && out.encoding == Encoding::UTF_8 && out.valid_encoding?
      names = names.each_with_index.map { |t, j| csv_text_in_utf8(t, "the name of column #{j}") }
      formatted = formatted.each_with_index.map do |fcol, j|
        fcol.each_with_index.map { |t, i| csv_text_in_utf8(t, "row #{i} of #{names[j].inspect}") }
      end
      out = csv_text(names, formatted, header, sep, quote)
    end

    if encoding
      out = begin
        out.encode(encoding)
      rescue Encoding::UndefinedConversionError => e
        raise csv_unwritable_cell(names, formatted, encoding) || e
      end
    end

    if path
      File.binwrite(path, out)
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

  # The summary line (nrow, variable data types, index) followed by the
  # middle-elided table.
  # @return [String]
  def inspect
    parts = @columns.map { |k, v| "#{k}:#{v.data_type}#{v.ndim > 1 ? v.shape[1..].inspect : ''}" }
    idx = @index ? " index=#{@axis_name.inspect}" : ""
    head = "#<CAFrame nrow=#{@nrow} vars=[#{parts.join(', ')}]#{idx}>"
    # The table counts the index as a column, so a frame whose only data is its
    # index has one to show.  Gate on the same thing render_table does.
    return head if @columns.empty? && @index.nil?
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

  # Render one N-D cell the way Array#inspect would, except that a masked
  # element prints as the table's missing marker rather than as UNDEF.
  private def format_nested_cell(v)
    case v
    when Array then "[" + v.map { |x| format_nested_cell(x) }.join(", ") + "]"
    else UNDEF.equal?(v) || v.nil? ? "_" : v.inspect
    end
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
      # An N-D cell renders its elements, and a masked element among them
      # takes the same marker a masked scalar does -- UNDEF's own inspect
      # would put a second spelling of "missing" in the same table.
      format_nested_cell(e.to_a)
    elsif e.is_a?(String)
      e
    elsif e.respond_to?(:iso8601)
      e.iso8601
    else
      e.to_s
    end
  end

  private def format_csv_column(col)
    # A float32 value goes out as its own shortest decimal ("0.1"), which
    # from_csv reads back as the same value, not as the double it widens
    # to ("0.10000000149011612"); cmplx64 has that in each part.
    if !col.face? && (col.data_type == CA_FLOAT32 || col.data_type == CA_CMPLX64)
      col = col.__shortest_float64__
    end
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

  private def csv_text(names, formatted, header, sep, quote)
    out = +""
    if header
      out << names.map { |t| quote_csv_field(t, sep, quote) }.join(sep) << "\n"
    end
    @nrow.times do |i|
      out << formatted.map { |fcol| quote_csv_field(fcol[i], sep, quote) }.join(sep) << "\n"
    end
    out
  end

  # The text of a cell as UTF-8, the encoding the CSV is built in: text in
  # another encoding is transcoded; bytes that are not valid in their
  # encoding, or have none (ASCII-8BIT), raise naming the cell.
  private def csv_text_in_utf8(text, where)
    return text if text.nil?
    enc = text.encoding
    unless text.valid_encoding?
      raise Encoding::InvalidByteSequenceError,
            "to_csv: #{where} (#{csv_excerpt(text)}) is not valid #{enc}"
    end
    return text if enc == Encoding::UTF_8 || (enc.ascii_compatible? && text.ascii_only?)
    if enc == Encoding::BINARY
      raise Encoding::CompatibilityError,
            "to_csv: #{where} (#{csv_excerpt(text)}) is bytes with no encoding " \
            "(ASCII-8BIT); give it one with force_encoding"
    end
    text.encode(Encoding::UTF_8)
  rescue Encoding::UndefinedConversionError
    raise Encoding::UndefinedConversionError,
          "to_csv: #{where} (#{csv_excerpt(text)}) has a character with no UTF-8 form in #{enc}"
  end

  # The start of a cell's text, quoted, for an error. Text is shown as it
  # is, whatever the locale (inspect would escape it where the locale is not
  # UTF-8); control characters and bytes that are not text are escaped.
  private def csv_excerpt(text)
    head = text[0, 20]
    return head.dump unless head.valid_encoding? && head.encoding != Encoding::BINARY
    head = head.encode(Encoding::UTF_8)
    '"' + head.gsub(/[\x00-\x1f\x7f"\\]/) { |c| c.dump[1..-2] } + '"'
  rescue EncodingError
    text[0, 20].dump
  end

  # The error for the first cell (or name) +encoding+ cannot hold, or nil.
  private def csv_unwritable_cell(names, formatted, encoding)
    cells = names.each_with_index.map { |t, j| [t, "the name of column #{j}"] }
    formatted.each_with_index do |fcol, j|
      fcol.each_with_index { |t, i| cells << [t, "row #{i} of #{names[j].inspect}"] if t }
    end
    cells.each do |text, where|
      text.encode(encoding)
    rescue Encoding::UndefinedConversionError => e
      return Encoding::UndefinedConversionError.new(
        "to_csv: #{where} (#{csv_excerpt(text)}): #{csv_excerpt(e.error_char)} (U+#{format("%04X", e.error_char.ord)}) cannot be written in #{encoding}")
    end
    nil
  end

  private def quote_csv_field(text, sep, quote)
    return "" if text.nil?
    # With a separator longer than one character, a value can end in part of
    # it ("a:" before "::"), and the reader would find the separator inside
    # the value; such a value is quoted too.
    if text.empty? || text.include?(sep) || text.include?(quote) ||
       text.include?("\n") || text.include?("\r") ||
       (sep.size > 1 && (text + sep).index(sep) != text.size)
      quote + text.gsub(quote, quote * 2) + quote
    else
      text
    end
  end

  # Build a frame from parsed [names, rows]. When names is nil (headerless and
  # no column_names) positional names "c0".."cN" are generated from the widest
  # row. Rows are squared off to the column count (short rows padded with nil,
  # over-long rows raise), one 2-D object array is bulk-filled, and each column
  # is a view into it (§3.6).
  def self.build_frame(names, rows)
    ncol  = if names then names.size
            elsif rows.is_a?(CArray) then rows.shape[1]
            else rows.map(&:size).max || 0
            end
    names ||= Array.new(ncol) { |j| "c#{j}" }
    # A frame holds one column per name, so a repeated one would keep only
    # the last of its columns.
    dup = names.tally.select { |_, count| count > 1 }.keys
    unless dup.empty?
      raise ArgumentError,
            "the header names #{dup.map(&:inspect).join(', ')} more than once; " \
            "name the columns yourself: from_csv(path, header: false, data: 1, " \
            "column_names: [...])"
    end

    cols = {}
    # A table the C reader built: one row per record, missing cells masked.
    table = rows if rows.is_a?(CArray) && rows.elements > 0
    if table.nil? && (rows.is_a?(CArray) || rows.empty?)
      names.each { |name| cols[name] = CArray.string(CArray.object(0)) }
      return new(cols)
    end
    table ||= table_of_rows(rows, ncol)
    # Each column is a CAString over its view of the table: the text, with
    # the string operations (strip!, gsub, extract, ...) at hand, writing
    # through to the same cells.
    names.each_with_index { |name, j| cols[name] = CArray.string(table[nil, j]) }
    new(cols)
  end
  private_class_method :build_frame

  def self.table_of_rows(rows, ncol)
    # A missing field is UNDEF, not a Ruby nil sitting in a cell.  The
    # tokenizer says missing with nil (an unquoted empty field; a quoted
    # one is the empty string and stays a value), and an object array will
    # hold that nil quite happily -- so a column read without `types:` used
    # to carry nil where the same column read with one carried UNDEF, and
    # the mask a to_csv had written did not survive the trip back.  A row
    # holding a nil gets UNDEF in its place before the table is built (an
    # UNDEF in the rows becomes a masked cell), so a row with nothing
    # missing costs no pass over its cells.  Short rows are padded, and a
    # row with a nil is changed, on a copy: the rows may be a parser:
    # callable's own arrays.
    rows = rows.each_with_index.map do |r, i|
      if r.size > ncol
        raise ArgumentError,
              "row #{i + 1} has #{r.size} fields, expected #{ncol}"
      end
      r = r + Array.new(ncol - r.size) if r.size < ncol
      # compact tests for nil without calling == on every cell, as
      # include?(nil) would.
      r = r.map { |cell| cell.nil? ? UNDEF : cell } if r.compact.size < ncol
      r
    end
    CArray.object(rows.size, ncol) { rows }
  end
  private_class_method :table_of_rows
end

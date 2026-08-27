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

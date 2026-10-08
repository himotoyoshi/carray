# CAFrame column verbs (memo §11.4, §12-A, §13.2).
#
# Each verb touches this frame's own columns Hash (per-frame, §12-B) and
# returns self so calls chain. Column data is still shared with any parent
# (view-frame), but membership — which columns this frame names — is local:
# append/drop/rename here never change a parent's column set.

class CAFrame
  # Add (or replace) a column, returning a new frame — the column set changes,
  # so the result is a different table (memo §3.8). The column is shared by
  # reference; the envelope is cheap. Chain or reassign: +df = df.append(...)+.
  def append(name, col)
    key = name.to_s
    ca  = coerce_column(col)
    rebuild(@columns.merge(key => ca))
  end

  # Remove one or more columns, returning a new frame (column set changes,
  # memo §3.8). Column data is untouched and shared with the original.
  def drop(*names)
    cols = @columns.dup
    names.each do |name|
      key = name.to_s
      raise KeyError, "no column #{key.inspect}" unless cols.key?(key)
      cols.delete(key)
    end
    rebuild(cols)
  end

  # Rename columns, returning a new frame (column names change, memo §3.8).
  # Column order is preserved (memo §13.2 "column order = insertion order");
  # columns are shared by reference.
  def rename(mapping)
    norm = {}
    mapping.each do |old, new|
      o = old.to_s
      n = new.to_s
      raise KeyError, "no column #{o.inspect}" unless @columns.key?(o)
      if n != o && @columns.key?(n)
        raise ArgumentError, "rename target #{n.inspect} already exists"
      end
      norm[o] = n
    end
    rebuilt = {}
    @columns.each { |k, v| rebuilt[norm[k] || k] = v }
    rebuild(rebuilt)
  end

  # Mask cells of a column that equal +value+ (sentinel -> mask, memo §11.4).
  # In-place on the column (write-through, §4.3): numeric/object columns
  # mask in place; a categorical column's codes are read-only (§13.4) so this
  # raises — recode by rebuilding and rebinding instead.
  def mask_eq(name, value)
    self[name][:eq, value] = UNDEF
    self
  end

  # Cast columns to a data type and rebind them (memo §11.4). A text column
  # cast to an integer or float type is read with a decimal grammar ("010" is
  # ten, "0x1F" and "1_000" are not numbers); a cell that does not read, or a
  # value the type cannot hold, becomes UNDEF (parse-mask, §6-2). A text
  # column cast to :time is parsed into a CATime column, in the finest unit
  # its text shows (:D for dates alone, :s with a time of day, :ms / :us /
  # :ns for fractions of a second); parse_to_time takes a format and a
  # unit. Other targets use to_type.
  # Three call shapes, disambiguated by the fact that column names are always
  # Strings and types always Symbols (§3.7):
  #
  #   cast("temp", :float64)                     # one column (chains)
  #   cast("temp" => :float64, "rh" => :int32)   # name => type map
  #   cast(["temp", "rh"] => :float64)           # names sharing one type
  #
  # A map key may be a single name or an Array of names; the value is the
  # target type. Returns self so calls chain.
  #
  # +on_error:+ says what to do with a text cell that holds something but
  # does not read as the number type ("x", "1.5" for an integer, "300" for
  # :int8). Blank, nil and masked cells are missing values, not errors, and
  # are UNDEF under every policy.
  #
  #   :mask   the cell becomes UNDEF (default)
  #   :warn   as :mask, plus one warning per column with the count and the
  #           first few cells
  #   :raise  ArgumentError naming the column, the row and the cell; no
  #           column is rebound
  def cast(name_or_map = nil, type = nil, on_error: :mask, **map)
    # A brace-less map (cast("temp" => :float64, on_error: :warn)) arrives as
    # keywords next to on_error:.
    unless map.empty?
      unless name_or_map.nil?
        raise ArgumentError, "cast takes a name and a type, or a map, not both"
      end
      name_or_map = map
    end
    raise ArgumentError, "cast needs a column name or a map" if name_or_map.nil?
    unless CAST_ON_ERROR.include?(on_error)
      raise ArgumentError,
            "on_error: must be :mask, :warn or :raise (got #{on_error.inspect})"
    end
    pairs =
      if name_or_map.is_a?(Hash)
        unless type.nil?
          raise ArgumentError, "cast(map) takes no positional type argument"
        end
        name_or_map.flat_map { |names, t| Array(names).map { |name| [name, t] } }
      else
        [[name_or_map, type]]
      end
    # Read every column before rebinding any, so a raise leaves the frame as
    # it was.
    casted = pairs.map { |name, t| [name.to_s, cast_column(name, t, on_error)] }
    casted.each { |key, col| @columns[key] = col }
    self
  end

  CAST_ON_ERROR = %i[mask warn raise].freeze
  private_constant :CAST_ON_ERROR

  # The types the text columns read as, as a map +cast+ takes:
  # { "temp" => :float64, "count" => :int64, "time" => :time }. A column is
  # listed only when every cell that is not missing reads as one type:
  # :int64 when they are all integers that fit, :float64 when they are all
  # numbers, :time when they are all year-first dates or times
  # ("2024-01-01", "2024-01-01 12:00:00", "2024-01-01T12:00:00.5Z").
  # Blank, nil and masked cells are missing and say nothing; a column with
  # none present is not listed.
  #
  # A number with a leading zero ("007") is a code and keeps its column as
  # text, and so does an integer too long for int64 (an identifier), which a
  # float would round. A day-first or month-first date ("01/02/2024") is not
  # read as time, since which one it is cannot be told. Columns that already
  # have a type are not listed.
  #
  #   df.cast(df.infer_types)                            # what types: :infer does
  #   df.cast(df.infer_types.merge("code" => :int32))    # with one column set by hand
  def infer_types
    @columns.each_with_object({}) do |(key, col), types|
      next unless col.data_type == CA_OBJECT && !col.face?
      type = col.__infer_decimal__
      type ||= :time if time_text_column?(col)
      types[key] = type if type
    end
  end

  # Bring every column to one common data type and rebind them (memo §11.4).
  # The frame-level counterpart of +CArray.promote_list+: where +cast+ forces
  # named columns to a type, +promote+ widens the whole table until it has a
  # single type. Returns self so calls chain (§3.8 -- a type-interpretation
  # change), and like +cast+ it allocates fresh columns, so a parent frame
  # sharing the old ones is untouched. The index is not a column and is left
  # alone.
  #
  #   df.promote             # the common type CArray.result_type would pick
  #   df.promote(:object)    # force the widest type: anything fits
  #
  # Without an argument the common type is whatever +promote_list+ picks --
  # the same decision +to_ca+ / +CArray.stack+ make internally, so
  # +df.promote+ is exactly "make this frame stackable". Columns that are
  # already uniform (including a uniformly Face-typed frame) are left as they
  # are.
  #
  # With an argument the type must be a widening for every column: promoting
  # is not the place to lose values, so a narrowing target raises and points
  # at +cast+, which is the verb that forces. +:object+ is the widest type
  # and therefore always accepted -- it is the way a frame mixing text,
  # Face-typed and numeric columns becomes a single-type table (and so the
  # way +to_ca+ can hand back a matrix for it).
  def promote(type = nil)
    return self if @columns.empty?
    type.nil? ? promote_to_common : promote_to_type(type)
    self
  end

  # Parse a string column into a time column and rebind it (memo §11.2).
  # The column must be string-bearing (an object CArray of Strings, or a
  # CAString / CAConstString / CAFixlenString) — this is the "text -> time"
  # mode, distinct from the integer-serial mode of +to_time+.
  #
  # Without +format+ only text written year first is read ("2024-01-01",
  # "2024/1/2 3:04", "2024-01-01T12:00:00.5Z"); a date in another order is
  # not, since whether "01/02/2024" is January or February cannot be told.
  # For those, +format+ is a strptime format, :infer to find the one format
  # the column is written in (see infer_time_format; a cell not in it
  # raises, whatever +on_error+ says), or :mixed to guess at each cell
  # (much slower). +unit+ is the storage resolution: without a format or
  # with :infer it defaults to the finest the text shows, with a format to
  # :s. Masked / nil and unparseable cells become UNDEF; +on_error:+ :warn /
  # :raise reports the unparseable ones as +cast+ does. Make it the index
  # with +set_index+ afterward. +cast(name => :time)+ is the call without a
  # format.
  #
  #   df.parse_to_time("time").set_index("time")
  #   df.parse_to_time("date", "%d/%m/%Y")
  #   df.parse_to_time("date", :infer)
  def parse_to_time(name, format = nil, unit: nil, on_error: :mask)
    unless CAST_ON_ERROR.include?(on_error)
      raise ArgumentError,
            "on_error: must be :mask, :warn or :raise (got #{on_error.inspect})"
    end
    key = name.to_s
    col = @columns.fetch(key) { raise KeyError, "no column #{key.inspect}" }
    unless string_column?(col)
      raise ArgumentError,
            "parse_to_time needs a string column (object / CAString / " \
            "CAConstString / CAFixlenString); #{key.inspect} is #{col.data_type}"
    end
    @columns[key] = parse_time_column(key, col, format, unit, on_error)
    self
  end

  # The strptime format parse_to_time(name, :infer) reads the column with,
  # or nil when the text is written year first and needs none. The first
  # present cell gives the candidates and each later cell drops those it
  # does not fit, until one is left; ArgumentError when none fits the first
  # cell, none is left, or more than one is left at the end (as for
  # "01/02/2024" when no cell has a day above 12). Write the answer into the
  # code to read the column with a format from then on.
  #
  #   df.infer_time_format("date")   # => "%d/%m/%Y"
  def infer_time_format(name)
    key = name.to_s
    col = @columns.fetch(key) { raise KeyError, "no column #{key.inspect}" }
    unless string_column?(col)
      raise ArgumentError, "column #{key.inspect} is #{col.data_type}, not text"
    end
    inferred_time_format(key, col)&.first&.format
  end

  # Reinterpret an integer column as time serial counts and rebind it (memo
  # §11.2). This is the "serial -> time" mode: each value is a count of
  # +unit+ resolution since +epoch+ (default the Unix epoch, 1970-01-01 UTC).
  # +epoch+ takes any time literal (String / Time / Integer), so a column
  # measured from another origin — a netCDF "hours since 1990-01-01" axis, an
  # Excel serial date (epoch "1899-12-30", unit :D) — converts directly.
  #
  # A float column is accepted only when every value is whole (no fractional
  # part); a fractional serial has sub-unit precision that a finer +unit+ should
  # carry, so it raises rather than silently truncate. Make it the index with
  # +set_index+ afterward.
  #
  # A +CATime::Grid+ carries the same (unit, epoch) pair as one value, so a
  # netCDF +units+ attribute goes straight in. It also carries a phase the
  # keyword form cannot: the keyword +epoch+ is read on the +unit+ grid, so
  # an epoch off that grid ("days since 1980-01-01 12:00") loses its
  # time-of-day, while a grid resolves the finer storage that holds it.
  #
  #   df.to_time("time", unit: :h, epoch: "1990-01-01").set_index("time")
  #   df.to_time("time", CATime::Grid.parse("hours since 1990-01-01"))
  #   df.to_time("time", CATime::Grid.parse("days since 1980-01-01 12:00"))
  def to_time(name, grid = nil, unit: :s, epoch: nil)
    key = name.to_s
    col = @columns.fetch(key) { raise KeyError, "no column #{key.inspect}" }
    raw = integer_serial_column(col, key)
    grid = unit if unit.is_a?(CATime::Grid)
    if grid.is_a?(CATime::Grid)
      @columns[key] = grid.at(raw)
      return self
    end
    unless grid.nil?
      raise ArgumentError,
            "the positional argument must be a CATime::Grid (got #{grid.class})"
    end
    if epoch
      raw = raw + CArray.time(epoch, unit: unit).ticks[0]
    end
    @columns[key] = raw.time(unit: unit)
    self
  end

  # Fill masked cells of a column (memo §6, §11.8).  A Symbol selects a
  # scan method; anything else is a constant fill value.  The fill is
  # write-through: it edits the live shared column rather than rebinding a
  # filled copy (memo §3.8).  Returns self so calls chain.
  #
  #   fill("temp", :ffill)   # forward hold  (carry last valid value)
  #   fill("temp", :bfill)   # backward hold (carry next valid value)
  #   fill("temp", :linear)  # linear interpolation; x = this frame's index
  #                          # coordinate when present, else the cell position
  #   fill("temp", 0.0)      # constant fill
  #
  # :ffill / :bfill work for any writable column data_type (numeric, time,
  # object, fixlen, …); :linear needs a numeric or time (CATime /
  # CATimedelta) column.  A categorical column's codes are read-only
  # (memo §13.4), so any fill on it raises — rebind a filled copy instead:
  # `df.append(name, df[name].strip_mask(method: :forward))`.
  def fill(name, method_or_value)
    key = name.to_s
    raise KeyError, "no column #{key.inspect}" unless @columns.key?(key)
    col = @columns[key]
    case method_or_value
    when :ffill  then col.unmask(method: :forward)
    when :bfill  then col.unmask(method: :backward)
    when :linear then fill_linear_column(key, col)
    when Symbol
      raise ArgumentError,
            "fill: unknown method #{method_or_value.inspect} " \
            "(:ffill | :bfill | :linear, or a constant fill value)"
    else
      col.unmask(method_or_value)   # constant fill, in place
    end
    self
  end

  private def fill_linear_column(key, col)
    # A time column interpolates through CATime#linear_fetch /
    # CATimedelta#linear_fetch, which keep the Face and its unit.
    time_face = col.is_a?(CATime) || col.is_a?(CATimedelta)
    unless col.numeric? || time_face
      raise ArgumentError,
            "fill(#{key.inspect}, :linear): numeric or time column required " \
            "(got #{col.data_type_name})"
    end
    # Without an index coordinate x is the cell position, which is exactly what
    # the core scan already interpolates against -- time columns included.
    return col.unmask(method: :linear) if @index.nil?
    # The same fill as the core, with the index as x.
    filled = col.send(:__linear_fill_along__, @index)
    if time_face
      # Write through the storage: a bulk store into the Face itself would try
      # to cast int64 ticks to its fixlen surface.  Both sides carry the same
      # unit (selection preserves it), so the ticks land exactly, mask included.
      col.parent[] = filled.parent
    else
      col[] = filled   # write-through
    end
  end

  # Text cells are data, not Ruby literals: an object column cast to a
  # number type is read as decimal numbers ("010" is ten, "0x1F" and "1_000"
  # are not numbers). Other targets go through to_type.
  private def cast_column(name, type, on_error)
    key = name.to_s
    col = @columns.fetch(key) { raise KeyError, "no column #{key.inspect}" }
    return cast_time_column(key, col, on_error) if type == :time
    return col.to_type(type) unless col.data_type == CA_OBJECT && !col.face?
    unreadable = on_error == :mask ? nil : []
    parsed = col.__parse_decimal__(type, unreadable)
    return col.to_type(type) unless parsed
    if unreadable && !unreadable.empty?
      report_unreadable(key, col, type, unreadable, on_error)
    end
    parsed
  end

  # cast(name => :time): year-first text to CATime, in the finest unit the
  # text shows.
  private def cast_time_column(key, col, on_error)
    unless string_column?(col)
      raise ArgumentError,
            "cast: column #{key.inspect} is #{col.data_type}, not text; " \
            "to_time reads a column of serial counts as time"
    end
    parse_time_column(key, col, nil, nil, on_error)
  end

  # Text to CATime. Without a format only year-first text is read; a
  # strptime format, or :mixed for a guess at each cell, goes through
  # CArray.time. Cells that hold something but do not parse are reported as
  # on_error says.
  private def parse_time_column(key, col, format, unit, on_error)
    case format
    when nil    then read_time_text(key, col, unit, on_error)
    when String then parse_time_by_format(key, col, format, unit || :s, on_error)
    when :infer then parse_time_inferred(key, col, unit)
    when :mixed then parse_time_by_format(key, col, nil, unit || :s, on_error)
    else
      raise ArgumentError,
            "time format must be a strptime String, :infer or :mixed " \
            "(got #{format.inspect})"
    end
  end

  # :infer reads the column in the one format its text is written in; a cell
  # that is not in it raises.
  private def parse_time_inferred(key, col, unit)
    f, fields, bad = inferred_time_format(key, col)
    return read_time_text(key, col, unit, :raise) if f.nil?
    unless fields[8].empty?
      cell = col.flatten[fields[8].first]
      raise ArgumentError, "column #{key.inspect} holds #{cell.inspect}, not text"
    end
    report_unreadable(key, col, f.format.inspect, [bad], :raise) if bad
    unit ||= case f.kind
             when :date  then :D
             when :clock then :s
             else
               digits = fields[9]
               digits > 6 ? :ns : digits > 3 ? :us : :ms
             end
    res = CATime::Resolution.parse(unit)
    unless CATimeLiteral.tick_kind(res)
      return parse_time_by_format(key, col, f.format, unit, :raise)
    end
    CATimeLiteral.ticks_from_fields(fields, col, res, f.format, :raise).time(unit: res)
  end

  # [format, fields, address of the first cell not in it] for :infer, or nil
  # when the text is written year first (or no cell is present), which
  # needs no format.
  private def inferred_time_format(key, col)
    text = time_text_of(col)
    first = text.flatten.to_a.find { |cell| !missing_text?(cell) }
    return nil if first.nil?
    unless first.is_a?(String)
      raise ArgumentError, "column #{key.inspect} holds #{first.inspect}, not text"
    end
    first = first.strip
    unreadable = []
    CA_OBJECT([first]).__parse_time_text__(nil, unreadable)
    return nil if unreadable.empty?
    CATimeLiteral.infer_time_format(text, first)
  end

  # The column as an object array of its text.
  private def time_text_of(col)
    (col.data_type == CA_OBJECT && !col.face?) ? col : col.to_type(:object)
  end

  # Year-first text, read in C. A unit the reader does not write itself is
  # reached by reading in the finest unit the text shows and converting.
  private def read_time_text(key, col, unit, on_error)
    text = time_text_of(col)
    unreadable = on_error == :mask ? nil : []
    ticks, read_unit = text.__parse_time_text__(unit, unreadable) ||
                       text.__parse_time_text__(nil, unreadable)
    if unreadable && !unreadable.empty?
      report_unreadable(key, col, :time, unreadable, on_error)
    end
    times = ticks.time(unit: read_unit)
    (unit.nil? || read_unit == unit) ? times : times.to_unit(unit)
  end

  # A strptime format, or nil for :mixed (a guess at each cell). The cells
  # that do not parse are reported as on_error says; blank text is missing.
  private def parse_time_by_format(key, col, format, unit, on_error)
    res = CATime::Resolution.parse(unit)
    text = time_text_of(col)
    fields = format && CATimeLiteral.tick_kind(res) &&
             text.__strptime_fields__(format, false)
    if fields
      parsed = CATimeLiteral.ticks_from_fields(fields, text, res, format, :mask)
                            .time(unit: res)
      return parsed if on_error == :mask
      cells = text.flatten.to_a
      masked = parsed.flatten
      addrs = (fields[7] + fields[8].select { |i| UNDEF.equal?(masked[i]) })
              .reject { |i| missing_text?(cells[i]) }.sort
    else
      parsed = CArray.time(col, format: format, unit: unit, on_error: :mask)
      return parsed if on_error == :mask
      failed = col.flatten.to_a.zip(parsed.flatten.is_masked.to_a)
      addrs = failed.each_index.select do |i|
        cell, masked = failed[i]
        masked && !missing_text?(cell)
      end
    end
    report_unreadable(key, col, :time, addrs, on_error) unless addrs.empty?
    parsed
  end

  # nil, UNDEF and a blank String are missing values.
  private def missing_text?(cell)
    cell.nil? || UNDEF.equal?(cell) || (cell.is_a?(String) && cell.strip.empty?)
  end

  # Whether every present cell of a text column is year-first text, and one
  # is present.
  private def time_text_column?(col)
    unreadable = []
    ticks, = col.__parse_time_text__(nil, unreadable)
    unreadable.empty? && ticks.count_not_masked > 0
  end

  # +addrs+ are flat addresses into +col+; a row holds elements / nrow cells.
  private def report_unreadable(key, col, type, addrs, on_error)
    cells = col.flatten
    per_row = col.elements / col.shape[0]
    describe = ->(addr) { "row #{addr / per_row} #{cells[addr].inspect}" }
    if on_error == :raise
      raise ArgumentError,
            "column #{key.inspect}, #{describe[addrs[0]]} cannot be read as #{type}"
    end
    shown = addrs.first(3).map(&describe)
    shown << "..." if addrs.size > 3
    noun, verb = addrs.size == 1 ? %w[cell is] : %w[cells are]
    warn "CAFrame#cast: column #{key.inspect}: #{addrs.size} #{noun} cannot be " \
         "read as #{type} and #{verb} UNDEF (#{shown.join(', ')})"
  end

  # +promote+ with no target: let +promote_list+ decide the common type --
  # the same call +to_ca+ / +CArray.stack+ make -- then materialise each
  # column it had to coerce. +promote_list+ hands a column back untouched
  # when it needs no coercion, so identity says which ones to rebind.
  private def promote_to_common
    cols = @columns.values
    begin
      promoted = CArray.promote_list(cols)
    rescue ArgumentError, RuntimeError => e
      raise ArgumentError,
            "#{e.message} -- promote(:object) brings every column to its " \
            "surface values, which any column set can share; a numeric target " \
            "works too when every Face column declares #to_numeric"
    end
    @columns.keys.each_with_index do |key, i|
      coerced = promoted[i]
      next if coerced.equal?(cols[i])
      @columns[key] = cols[i].to_type(coerced.data_type)
    end
  end

  # +promote+ with a target: every column must widen into it.
  private def promote_to_type(type)
    unless type.is_a?(Symbol)
      raise ArgumentError,
            "promote takes a data type Symbol (got #{type.class}); " \
            "class-shaped targets are not promotion destinations"
    end
    # Check every column before rebinding any. A column that would narrow
    # rejects the whole promote, and rejecting part way through would leave the
    # frame promoted in whichever columns happened to come first.
    #
    # A Face column answers for itself: :object is its surface values, a
    # numeric target is whatever it declares in #to_numeric (and a TypeError
    # naming that method when it declares nothing). result_type has nothing
    # to say about a surface it cannot read, so the widening check -- which
    # is about primitive promotion -- applies to plain columns only.
    @columns.each { |key, col| refuse_narrowing(key, col, type) unless col.face? }
    @columns.each_key { |key| @columns[key] = @columns[key].to_type(type) }
  end

  private def refuse_narrowing(key, col, type)
    common = begin
      CArray.result_type(col, type)
    rescue StandardError => e
      raise ArgumentError,
            "promote: column #{key.inspect} (#{col.data_type}) has no common " \
            "type with #{type.inspect} (#{e.message})"
    end
    return if common == type
    raise ArgumentError,
          "promote widens: column #{key.inspect} (#{col.data_type}) would " \
          "narrow to #{type.inspect} -- cast is the verb that forces a " \
          "lossy change"
  end

  private def string_column?(col)
    col.is_a?(CArray::StringOperationMixin) || col.data_type == :object
  end

  private def integer_serial_column(col, key)
    if INTEGER_TYPES.include?(col.data_type)
      col.to_type(:int64)
    elsif col.data_type == :float32 || col.data_type == :float64
      unless col.floor.eq(col).all
        raise ArgumentError,
              "to_time: float column #{key.inspect} has fractional values; " \
              "use a finer unit: or convert to integer counts explicitly"
      end
      col.to_type(:int64)
    else
      raise ArgumentError,
            "to_time needs an integer serial column; #{key.inspect} is #{col.data_type}"
    end
  end
end

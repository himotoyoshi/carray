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

  # Cast columns to a data type and rebind them (memo §11.4). Uses to_type,
  # so parse failures on string columns become UNDEF (parse-mask, §6-2).
  # Three call shapes, disambiguated by the fact that column names are always
  # Strings and types always Symbols (§3.7):
  #
  #   cast("temp", :float64)                     # one column (chains)
  #   cast("temp" => :float64, "rh" => :int32)   # name => type map
  #   cast(["temp", "rh"] => :float64)           # names sharing one type
  #
  # A map key may be a single name or an Array of names; the value is the
  # target type. Returns self so calls chain.
  def cast(name_or_map, type = nil)
    if name_or_map.is_a?(Hash)
      unless type.nil?
        raise ArgumentError, "cast(map) takes no positional type argument"
      end
      name_or_map.each do |names, t|
        Array(names).each { |name| cast_one(name, t) }
      end
    else
      cast_one(name_or_map, type)
    end
    self
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
  # mode, distinct from the integer-serial mode of +to_time+. Delegates to
  # +CArray.time(col, on_error: :mask)+: +format+ picks strptime parsing
  # (auto-detect when nil), +unit+ the storage resolution; masked / nil and
  # unparseable cells become UNDEF (bulk column parse tolerates bad cells).
  # Make it the index with +set_index+ afterward.
  #
  #   df.parse_to_time("time").set_index("time")
  def parse_to_time(name, format = nil, unit: :s)
    key = name.to_s
    col = @columns.fetch(key) { raise KeyError, "no column #{key.inspect}" }
    unless string_column?(col)
      raise ArgumentError,
            "parse_to_time needs a string column (object / CAString / " \
            "CAConstString / CAFixlenString); #{key.inspect} is #{col.data_type}"
    end
    @columns[key] = CArray.time(col, format: format, unit: unit, on_error: :mask)
    self
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
    present = col.is_not_masked
    return if present.count(true) < 2
    addr = @index[present].linear_section(@index)
    if time_face
      filled = col[present].linear_fetch(addr)   # UNDEF beyond the valid span
      # Write through the storage: a bulk store into the Face itself would try
      # to cast int64 ticks to its fixlen surface.  Both sides carry the same
      # unit (selection preserves it), so the ticks land exactly, mask included.
      col.parent[] = filled.parent
      return
    end
    yvalid = col.value.float64[present]
    col[] = yvalid.linear_fetch(addr).to_type(col.data_type).mask_invalid   # write-through
  end

  private def cast_one(name, type)
    key = name.to_s
    raise KeyError, "no column #{key.inspect}" unless @columns.key?(key)
    @columns[key] = @columns[key].to_type(type)
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
    @columns.each_key do |key|
      col = @columns[key]
      # A Face column answers for itself: :object is its surface values, a
      # numeric target is whatever it declares in #to_numeric (and a TypeError
      # naming that method when it declares nothing). result_type has nothing
      # to say about a surface it cannot read, so the widening check -- which
      # is about primitive promotion -- applies to plain columns only.
      refuse_narrowing(key, col, type) unless col.face?
      @columns[key] = col.to_type(type)
    end
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

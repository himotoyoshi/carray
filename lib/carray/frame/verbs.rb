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

  # Split a text column at +sep+ into the columns named by +into:+,
  # returning a new frame where they take the column's place:
  #
  #   df.split_column("code", "-", into: ["kind", "num"])   # "A-12" -> "A", "12"
  #
  # A cell is split into at most +into.size+ pieces, so the rest of a cell
  # with more separators stays in the last column rather than being dropped,
  # and the columns a cell with fewer separators does not reach are UNDEF. A
  # masked cell is UNDEF in every new column. +sep+ is a String or a Regexp,
  # as String#split takes it; a group in the Regexp would add pieces, so use
  # (?:...). The new columns are CAString, ready for cast.
  #
  # @param name [String] the text column to split.
  # @param sep [String, Regexp] where to split.
  # @param into [Array<String>] the names of the new columns, two or more.
  # @return [CAFrame] a new frame; the other columns are shared.
  # @raise [ArgumentError] when the column is not text or 1-D, +into:+ names
  #   fewer than two columns or one twice, or names a column already there.
  def split_column(name, sep, into:)
    key = name.to_s
    col = @columns.fetch(key) { raise KeyError, "no column #{key.inspect}" }
    unless string_column?(col) && col.ndim == 1
      raise ArgumentError, "split_column: #{key.inspect} is not a one-dimensional text column"
    end
    unless sep.is_a?(String) || sep.is_a?(Regexp)
      raise ArgumentError, "split_column: sep must be a String or a Regexp (got #{sep.inspect})"
    end
    names = Array(into).map(&:to_s)
    if names.size < 2 || names.uniq.size != names.size
      raise ArgumentError,
            "split_column: into: names two or more columns, each once (got #{names.inspect})"
    end
    taken = names & (@columns.keys - [key])
    unless taken.empty?
      raise ArgumentError, "split_column: #{taken.inspect} already a column"
    end

    n = names.size
    pieces = Array.new(n) { CArray.object(col.elements) }
    pieces.each { |p| p[] = UNDEF }
    time_text_of(col).to_a.each_with_index do |cell, i|
      next if UNDEF.equal?(cell) || cell.nil?
      cell.split(sep, n).each_with_index { |part, k| pieces[k][i] = part }
    end
    rebuilt = {}
    @columns.each do |k, v|
      if k == key
        names.each_with_index { |nm, j| rebuilt[nm] = CArray.string(pieces[j]) }
      else
        rebuilt[k] = v
      end
    end
    rebuild(rebuilt)
  end

  # Stack several columns into one N-D column: the columns side by side in a
  # file -- a value per month, say -- become one column whose trailing axis
  # (or axes, with +shape:+) runs over them.  The columns are given in the
  # frame's order:
  #
  #   df.stack_columns("G02_002".."G02_013", into: "precip")   # 12 columns
  #   df.stack_columns(%w[t_max t_min t_mean], into: "temp")
  #   df.stack_columns(/\Ahour_\d+\z/, into: "temp")
  #   df.stack_columns("G02_015".."G02_050", into: "temp", shape: [12, 3])
  #
  # A Range of names means the columns of this frame from the first name to
  # the last, in the frame's order -- not the names Ruby would count between
  # the two -- and an exclusive Range leaves the last one out.  An Array is
  # taken in its own order, a Regexp in the frame's.  +shape:+ arranges the
  # stacked columns in row-major order (the last axis runs fastest) and must
  # hold exactly that many.  Columns that are themselves N-D keep their axes
  # after the new ones.  +into:+ is the new column's name, a String.
  #
  # The new column is a view of the old ones, so writes reach them; it takes
  # the place of the first of them, and the others leave the frame.  The
  # trailing axes carry no labels: keep what position k means (the months)
  # alongside.  +unstack_column+ goes the other way; +stack_columns+ of the
  # columns it gives, into the same name, gives this column back.
  #
  # @return [CAFrame] a new frame; the other columns are shared.
  def stack_columns(selection, into:, shape: nil)
    names = columns_selected(selection, "stack_columns")
    target = column_name_arg(into, "stack_columns")
    taken = [target] & (@columns.keys - names)
    unless taken.empty?
      raise ArgumentError, "stack_columns: #{target.inspect} is already a column"
    end
    parts = names.map { |n| @columns[n] }
    trailing = parts.first.shape[1..]
    parts.each_with_index do |c, i|
      next if c.shape[1..] == trailing
      raise ArgumentError,
            "stack_columns: #{names[i].inspect} has shape #{c.shape.inspect}, " \
            "#{names.first.inspect} has #{parts.first.shape.inspect}"
    end
    layer = shape ? Array(shape) : [names.size]
    unless layer.all? { |d| d.is_a?(Integer) && d > 0 } && layer.inject(:*) == names.size
      raise ArgumentError,
            "stack_columns: shape: #{layer.inspect} does not hold the #{names.size} columns"
    end
    col = CArray.stack(parts, axis: 1)
    col = col.reshape(nrow, *layer, *trailing) if layer.size > 1
    rebuilt = {}
    @columns.each do |k, v|
      if k == names.first
        rebuilt[target] = col
      elsif ! names.include?(k)
        rebuilt[k] = v
      end
    end
    rebuild(rebuilt)
  end

  # Split an N-D column into one column per position on its trailing axes --
  # the other way from +stack_columns+.  The new columns are views of the N-D
  # column, in row-major order, and take its place in the frame.  +into:+
  # names them (as many names as positions); without it they are named
  # after the column and the position, "temp_0", or "temp_6_2" with two
  # axes.  The frame does not remember the names the columns had before
  # +stack_columns+, so pass them as +into:+ to get them back.
  #
  # When +into:+ names as many columns as the first trailing axis is long,
  # the column is split along that axis only, and each new column keeps the
  # axes after it: a (n, 2, 3) column with two names gives two (n, 3)
  # columns.  This undoes +stack_columns+ of columns that were N-D.
  #
  # A column whose trailing axes hold no position has nothing to split into
  # and is refused.
  #
  # @return [CAFrame] a new frame; the other columns are shared.
  def unstack_column(name, into: nil)
    key = name.to_s
    col = @columns.fetch(key) { raise KeyError, "no column #{key.inspect}" }
    if col.ndim < 2
      raise ArgumentError, "unstack_column: #{key.inspect} is one-dimensional; there is nothing to unstack"
    end
    trailing = col.shape[1..]
    count = trailing.inject(:*)
    if count == 0
      raise ArgumentError,
            "unstack_column: #{key.inspect} has shape #{col.shape.inspect}; " \
            "its trailing axes hold no position to split into"
    end
    given = into && Array(into).map { |n| column_name_arg(n, "unstack_column") }
    if given && trailing.size > 1 && given.size == trailing.first
      positions = (0...trailing.first).map { |k| [k] }
      count = trailing.first
    else
      positions = trailing.size == 1 ? (0...count).map { |k| [k] } :
                    trailing.map { |d| (0...d).to_a }.inject { |a, b| a.product(b).map(&:flatten) }
    end
    names = given || positions.map { |pos| "#{key}_#{pos.join('_')}" }
    unless names.size == count && names.uniq.size == count
      raise ArgumentError,
            "unstack_column: into: names #{names.size} columns, each once; #{key.inspect} has #{count} positions"
    end
    taken = names & (@columns.keys - [key])
    unless taken.empty?
      raise ArgumentError, "unstack_column: #{taken.inspect} already a column"
    end
    rebuilt = {}
    @columns.each do |k, v|
      if k == key
        rest = [nil] * (v.ndim - 1 - positions.first.size)
        positions.each_with_index { |pos, j| rebuilt[names[j]] = v[nil, *pos, *rest] }
      else
        rebuilt[k] = v
      end
    end
    rebuild(rebuilt)
  end

  # A column name given as an argument: a non-empty String, as the frame's
  # column keys are.
  private def column_name_arg(name, verb)
    unless name.is_a?(String)
      raise TypeError, "#{verb}: a column name is a String (got #{name.inspect})"
    end
    raise ArgumentError, "#{verb}: a column name can not be empty" if name.empty?
    name
  end

  # The names a column selection picks: a Range of names spans the frame's
  # columns from one to the other, an Array is taken as given, a Regexp
  # matches in the frame's order.
  private def columns_selected(selection, verb)
    keys = @columns.keys
    names = case selection
            when Range
              from, to = selection.begin, selection.end
              unless from.is_a?(String) && to.is_a?(String)
                raise ArgumentError, "#{verb}: a Range of column names takes two names (got #{selection.inspect})"
              end
              i = keys.index(from) or raise KeyError, "#{verb}: no column #{from.inspect}"
              j = keys.index(to)   or raise KeyError, "#{verb}: no column #{to.inspect}"
              if j < i
                raise ArgumentError, "#{verb}: #{to.inspect} comes before #{from.inspect} in the frame"
              end
              keys[i..(selection.exclude_end? ? j - 1 : j)]
            when Array
              selection.map(&:to_s).each do |n|
                raise KeyError, "#{verb}: no column #{n.inspect}" unless @columns.key?(n)
              end
            when Regexp
              keys.grep(selection)
            else
              raise ArgumentError,
                    "#{verb}: columns are a Range of names, an Array of names or a Regexp (got #{selection.class})"
            end
    if names.empty?
      raise ArgumentError, "#{verb}: #{selection.inspect} selects no column"
    end
    if names.uniq.size != names.size
      raise ArgumentError, "#{verb}: #{selection.inspect} names a column more than once"
    end
    names
  end

  # Mask cells of a column that equal +value+ (sentinel -> mask, memo §11.4).
  # In-place on the column (write-through, §4.3): numeric/object columns
  # mask in place; a categorical column's codes are read-only (§13.4) so this
  # raises — recode by rebuilding and rebinding instead.
  def mask_eq(name, value)
    refuse_if_frozen
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
  # The call shapes are told apart by the fact that column names are always
  # Strings and types always Symbols (§3.7):
  #
  #   cast("temp", :float64)                     # one column (chains)
  #   cast("temp" => :float64, "rh" => :int32)   # name => type map
  #   cast(["temp", "rh"] => :float64)           # names sharing one type
  #   cast(:infer)                               # what infer_types finds
  #   cast(default: :infer, "code" => :int32)    # a default for the rest
  #
  # A map key may be a single name or an Array of names; the value is the
  # target type, or nil to leave the column as it is. The map may be given
  # with or without braces.
  #
  # +default:+ in the map covers the columns the map does not name: :infer
  # casts the ones among them that +infer_types+ finds a type for, and a type
  # casts all of them. A named column takes its own entry, which replaces
  # the default. +:infer+ alone is +{ default: :infer }+.
  #
  #   cast(default: :infer, "id" => nil)         # infer, but leave "id"
  #   cast(default: :float64, "station" => nil)  # every other column to float64
  #
  # A name that is not a column raises KeyError, and a Symbol key other than
  # +:default+ raises ArgumentError; both before any column is read. Every
  # column is read before any is rebound, so a raise leaves the frame as it
  # was. Returns self so calls chain.
  #
  # +on_error:+ says what to do with a text cell that holds something but
  # does not read as the number type ("x", "1.5" for an integer, "300" for
  # :int8). Blank, nil and masked cells are missing values, not errors, and
  # are UNDEF under every policy.
  #
  #   :mask   the cell becomes UNDEF (default)
  #   :warn   as :mask, plus one warning per column with the count and the
  #           first few cells
  #   :raise  CAFrame::UnreadableColumn naming the column, the row and the
  #           cell; no column is rebound
  #
  # +option_name:+ is for a method that takes the map as one of its own
  # options and hands it to cast, as from_csv does with +types:+. An error
  # about the map then names that option instead of cast, and the map must
  # be a Hash or :infer:
  #
  #   frame.cast(types, on_error: on_error, option_name: :types)
  def cast(name_or_map = nil, type = nil, on_error: :mask, option_name: nil, **map)
    refuse_if_frozen
    label = option_name ? "#{option_name}:" : "cast"
    # A brace-less map (cast("temp" => :float64, on_error: :warn)) arrives as
    # keywords next to on_error:.
    unless map.empty?
      unless name_or_map.nil?
        raise ArgumentError, "#{label} takes a name and a type, or a map, not both"
      end
      name_or_map = map
    end
    raise ArgumentError, "#{label} needs a column name or a map" if name_or_map.nil?
    unless CAST_ON_ERROR.include?(on_error)
      raise ArgumentError,
            "on_error: must be :mask, :warn or :raise (got #{on_error.inspect})"
    end
    name_or_map = { default: :infer } if name_or_map == :infer && type.nil?
    if option_name && !name_or_map.is_a?(Hash)
      raise ArgumentError, "#{label} takes a map of column types or :infer " \
                           "(got #{name_or_map.inspect})"
    end
    types =
      if name_or_map.is_a?(Hash)
        unless type.nil?
          raise ArgumentError, "#{label} takes no positional type argument with a map"
        end
        resolve_cast_map(name_or_map, label)
      else
        { name_or_map.to_s => type }
      end
    # Read every column before rebinding any, so a raise leaves the frame as
    # it was.
    casted = types.map { |key, t| [key, cast_column(key, t, on_error)] }
    casted.each { |key, col| @columns[key] = col }
    self
  end
  
  # The name => type pairs a cast map asks for: the named columns with a
  # type, then the columns default: covers. Checks the keys and the names
  # before anything is read.
  private def resolve_cast_map(map, label)
    default = nil
    named = {}
    map.each do |key, t|
      if key == :default
        default = t
      elsif key.is_a?(Symbol)
        raise ArgumentError, "#{label} takes column names (Strings) and :default " \
                             "as keys (got #{key.inspect})"
      else
        Array(key).each { |name| named[name.to_s] = t }
      end
    end
    named.each_key do |name|
      raise KeyError, "#{label} names no column #{name.inspect}" unless @columns.key?(name)
    end
    rest = @columns.keys - named.keys
    types =
      case default
      when nil    then {}
      when :infer then rest.empty? ? {} : select(*rest).infer_types
      else             rest.to_h { |name| [name, default] }
      end
    types.merge!(named.compact)
  end
  
  CAST_ON_ERROR = %i[mask warn raise].freeze

  # The targets a text column is read as numbers for.
  CAST_NUMBER_TYPES = %w[int8 int16 int32 int64 uint8 uint16 uint32 uint64
                         float32 float64 cmplx64 cmplx128].freeze
  private_constant :CAST_ON_ERROR, :CAST_NUMBER_TYPES

  # The types the text columns read as, as a map +cast+ takes:
  # { "temp" => :float64, "count" => :int64, "time" => :time }. A column is
  # listed only when every cell that is not missing reads as one type:
  # :int64 when they are all integers that fit, :float64 when they are all
  # numbers, :boolean when they are all true / false (in any case), :time
  # when they are all year-first dates or times ("2024-01-01",
  # "2024-01-01 12:00:00", "2024-01-01T12:00:00.5Z"). 0 / 1 is :int64: a
  # column of those is read as the integers it could equally be, and
  # cast("name" => :boolean) turns it into a boolean.
  # Blank, nil and masked cells are missing and say nothing; a column with
  # none present is not listed.
  #
  # A number with a leading zero ("007") is a code and keeps its column as
  # text, and so does an integer too long for int64 (an identifier), which a
  # float would round. A day-first or month-first date ("01/02/2024") is not
  # read as time, since which one it is cannot be told. Only text columns
  # are looked at -- an object column or a string Face (CAString,
  # CAConstString); columns that already have a type are not listed.
  #
  #   df.cast(df.infer_types)                            # what cast(:infer) does
  #   df.cast(df.infer_types.merge("code" => :int32))    # as cast(default: :infer, "code" => :int32)
  def infer_types
    @columns.each_with_object({}) do |(key, col), types|
      next unless string_column?(col)
      type = text_for_decimal_reading(col).__infer_number_type_of_text__
      type ||= :boolean if boolean_word_column?(col)
      type ||= :time if first_present_cell_can_be_time_text?(col) && time_text_column?(time_text_of(col))
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
    refuse_if_frozen
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
  # raises CAFrame::UnreadableColumn, whatever +on_error+ says), or :mixed
  # to guess at each cell (much slower). +unit+ is the storage resolution:
  # without a format or with :infer it defaults to the finest the text
  # shows, with a format to :s. Masked / nil and unparseable cells become
  # UNDEF; +on_error:+ :warn / :raise reports the unparseable ones as +cast+
  # does. Make it the index with +set_index+ afterward.
  # +cast(name => :time)+ is the call without a format.
  #
  #   df.parse_to_time("time").set_index("time")
  #   df.parse_to_time("date", "%d/%m/%Y")
  #   df.parse_to_time("date", :infer)
  def parse_to_time(name, format = nil, unit: nil, on_error: :mask)
    refuse_if_frozen
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
  # does not fit, until one is left. CAFrame::UnreadableColumn when none fits
  # the first cell or none is left; CAFrame::AmbiguousTimeFormat when more
  # than one is left at the end (as for "01/02/2024" when no cell has a day
  # above 12), whose +formats+ lists them. Write the answer into the code to
  # read the column with a format from then on.
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
  # part); a fractional serial has sub-unit precision that a finer +unit+
  # should carry, so it raises CAFrame::UnreadableColumn rather than
  # silently truncate. Make it the index with +set_index+ afterward.
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
    refuse_if_frozen
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
    refuse_if_frozen
    key = name.to_s
    raise KeyError, "no column #{key.inspect}" unless @columns.key?(key)
    col = @columns[key]
    # An N-D column is filled down the rows: each position on its trailing
    # axes is a series of its own.
    along = col.ndim > 1 ? { axis: 0 } : {}
    case method_or_value
    when :ffill  then col.unmask(method: :forward, **along)
    when :bfill  then col.unmask(method: :backward, **along)
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
    if @index.nil?
      return col.unmask(method: :linear, **(col.ndim > 1 ? { axis: 0 } : {}))
    end
    # With the index as x, an N-D column is filled one trailing position at a
    # time; each position is a 1-D view, so the fill writes through to it.
    if col.ndim > 1
      col.shape[1..].map { |d| (0...d).to_a }.inject { |a, b| a.product(b).map { |e| Array(e).flatten } }
         .each { |pos| fill_linear_column(key, col[nil, *Array(pos)]) }
      return
    end
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
    if CArray.data_type_name(type) == "boolean"
      return read_boolean_text(key, col, on_error) if string_column?(col)
      if !col.face? && INTEGER_TYPES.include?(col.data_type)
        return read_boolean_integers(key, col, on_error)
      end
    end
    unless string_column?(col) && CAST_NUMBER_TYPES.include?(CArray.data_type_name(type))
      return col.to_type(type)
    end
    # Text cast to a number -- from an object column or a string Face -- is
    # read the same way, so the decimal grammar and on_error: hold for all.
    text = text_for_decimal_reading(col)
    unreadable = on_error == :mask ? nil : []
    parsed = text.__read_text_as_number__(type, unreadable)
    unless parsed
      # A target the decimal reader does not take (complex) goes through
      # to_type; a cell that held something and came back masked did not read.
      text = time_text_of(col)
      parsed = text.to_type(type)
      if unreadable
        cells = text.flatten.to_a
        masked = parsed.flatten.is_masked.to_a
        unreadable = cells.each_index.select { |i| masked[i] && !missing_text?(cells[i]) }
      end
    end
    if unreadable && !unreadable.empty?
      report_unreadable(key, col, type, unreadable, on_error)
    end
    parsed
  end

  # Text a boolean column is read from: what to_csv writes (0 / 1) and the
  # words other tools write (true / false in any case). Surrounding spaces
  # are ignored; a missing cell is UNDEF; anything else does not read.
  BOOLEAN_TEXT = { "1" => true, "0" => false, "true" => true, "false" => false }.freeze
  private_constant :BOOLEAN_TEXT

  # cast(name => :boolean) on a text column. The distinct texts are judged
  # once each and the answer is spread over the cells, so a column of many
  # rows is not walked in Ruby.
  private def read_boolean_text(key, col, on_error)
    text = time_text_of(col)
    trues, known, bad = [], [], []
    text.unique.to_a.each do |v|
      next if missing_text?(v)
      case BOOLEAN_TEXT[v.to_s.strip.downcase]
      when true  then trues << v; known << v
      when false then known << v
      else            bad << v
      end
    end
    out = text.is_in(trues)
    unknown = text.is_in(known).not
    unknown = unknown.strip_mask(false) if unknown.has_mask?
    if on_error != :mask && !bad.empty?
      addrs = text.is_in(bad)
      addrs = addrs.strip_mask(false) if addrs.has_mask?
      report_unreadable(key, col, :boolean, addrs.flatten.where.to_a, on_error)
    end
    out[unknown] = UNDEF if unknown.any
    out
  end

  # cast(name => :boolean) on an integer column: 0 is false, 1 is true, and
  # any other value does not read (on_error: says what becomes of it).
  private def read_boolean_integers(key, col, on_error)
    bad = col.ne(0) & col.ne(1)
    bad = bad.strip_mask(false) if bad.has_mask?
    out = col.eq(1)
    if bad.any
      report_unreadable(key, col, :boolean, bad.flatten.where.to_a, on_error) unless on_error == :mask
      out[bad] = UNDEF
    end
    out
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
  rescue RangeError => e
    raise unless e.message.include?("does not fit int64 ticks")
    raise RangeError, "column #{key.inspect}: #{e.message}; parse_to_time takes " \
                      "unit: to read it in a coarser unit (:us spans 292,000 years)"
  end

  # :infer reads the column in the one format its text is written in; a cell
  # that is not in it raises.
  private def parse_time_inferred(key, col, unit)
    f, fields, bad = inferred_time_format(key, col)
    return read_time_text(key, col, unit, :raise) if f.nil?
    unless fields[8].empty?
      cell = col.flatten[fields[8].first]
      raise UnreadableColumn, "column #{key.inspect} holds #{cell.inspect}, not text"
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
      raise UnreadableColumn, "column #{key.inspect} holds #{first.inspect}, not text"
    end
    first = first.strip
    unreadable = []
    begin
      CA_OBJECT([first]).__parse_time_text__(nil, unreadable)
    rescue RangeError
      return nil                   # year first, only too far out for its unit
    end
    return nil if unreadable.empty?
    CATimeLiteral.infer_time_format(text, first)
  end

  # The column as an object array of its text. A CAString already holds one,
  # as its parent; other string Faces convert.
  # The column as the decimal readers take it: a CAConstString is read from
  # its buffer, the rest as time_text_of gives them.
  private def text_for_decimal_reading(col)
    col.is_a?(CAConstString) ? col : time_text_of(col)
  end

  private def time_text_of(col)
    return col if col.data_type == CA_OBJECT && !col.face?
    return col.parent if col.is_a?(CAString)
    col.to_type(:object)
  end

  # Year-first text, read in C. A unit the reader does not write itself is
  # reached by reading in the finest unit the text shows and converting.
  # The reader is asked only for a unit of one base tick (:s, :ms, ...), given
  # as a Symbol; any unit spelling (a String, a CATime::Resolution) is
  # normalized first.
  private def read_time_text(key, col, unit, on_error)
    text = time_text_of(col)
    res = unit && CATime::Resolution.parse(unit)
    base = res && res.count == 1 ? res.base : nil
    unreadable = on_error == :mask ? nil : []
    # Read wide: the column is time by the caller's word, so a year past
    # 9999 and a date that stops at the month or the year (what to_csv writes
    # for those) read too.  Trying text as time (infer_types) reads strictly.
    ticks, read_unit = (base && text.__parse_time_text__(base, unreadable, true)) ||
                       text.__parse_time_text__(nil, unreadable, true)
    if unreadable && !unreadable.empty?
      report_unreadable(key, col, :time, unreadable, on_error)
    end
    times = ticks.time(unit: read_unit)
    (res.nil? || read_unit == base) ? times : times.to_unit(res)
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
  # Every present cell is true or false in some case, and one is present.
  private def boolean_word_column?(col)
    words = time_text_of(col).unique.to_a.reject { |v| missing_text?(v) }
    !words.empty? && words.all? { |v| %w[true false].include?(v.to_s.strip.downcase) }
  end

  private def missing_text?(cell)
    cell.nil? || UNDEF.equal?(cell) || (cell.is_a?(String) && cell.strip.empty?)
  end

  # A column is time text only if every present cell is, so one cell that
  # holds something and does not read settles it without reading the rest.
  # Only a refusal is taken from it: a blank cell says nothing.
  private def first_present_cell_can_be_time_text?(col)
    i = 0
    if col.has_mask?
      present = col.is_not_masked.where
      return true if present.elements == 0
      i = present[0]
    end
    return true if col.elements == 0
    unreadable = []
    time_text_of(col[i..i]).__parse_time_text__(nil, unreadable)
    unreadable.empty?
  rescue RangeError
    true
  end

  # Whether every present cell of a text column is year-first text, and one
  # is present. A time too far out for the unit its text shows is still time
  # text; the cast that follows says it does not fit.
  private def time_text_column?(col)
    unreadable = []
    ticks, = col.__parse_time_text__(nil, unreadable)
    unreadable.empty? && ticks.count_not_masked > 0
  rescue RangeError
    unreadable.empty?              # the reader lists unreadable cells before it raises
  end

  # +addrs+ are flat addresses into +col+; a row holds elements / nrow cells.
  private def report_unreadable(key, col, type, addrs, on_error)
    cells = col.flatten
    per_row = col.elements / col.shape[0]
    describe = ->(addr) { "row #{addr / per_row} #{cells[addr].inspect}" }
    if on_error == :raise
      raise UnreadableColumn,
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
    rescue ArgumentError, TypeError, CArray::DataTypeError => e
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
        raise UnreadableColumn,
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

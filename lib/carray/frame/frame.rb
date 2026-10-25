# CAFrame — DataFrame built on CArray columns.
#
# Internal structure (memo §3): a Hash of named columns, an axis name for
# the row axis, and an optional index column. Every column agrees on its
# axis-0 length N; trailing shape is free per column (§3.2). The only
# substance the frame adds is names — the columns themselves are borrowed
# CArrays and are handed back raw so callers escape to CArray (§4.3).
#
# View semantics follow CArray (§3.6): +df["col"]+ is the stored column
# itself (an alias), row slices and filters return view-frames sharing
# storage, and +copy+ is the way to an independent frame.

class CAFrame
  # Raised when the contents of a column cannot be read as asked: a cell
  # that does not read as the type a +cast+ (or +read_csv+'s +types:+) asks
  # for under on_error: :raise, a cell +parse_to_time+ cannot read, a column
  # whose time format +infer_time_format+ / parse_to_time(name, :infer)
  # cannot find, or a float column +to_time+ cannot read as whole counts.
  # The message names the column and the cell. The arguments were fine; the
  # column's contents are what did not read.
  class UnreadableColumn < StandardError; end

  # Raised when +infer_time_format+ / parse_to_time(name, :infer) finds more
  # than one format every cell fits ("01/02/2024" and "03/04/2024" are both
  # day-first and month-first). The text reads in each of them, so it is
  # not an UnreadableColumn; +formats+ gives the candidates, to choose one and
  # pass it as the format.
  class AmbiguousTimeFormat < StandardError
    attr_reader :formats

    def initialize(message = nil, formats: [])
      @formats = formats
      super(message)
    end
  end

  # Integer data_types that select rows positionally when used as a df[] key.
  INTEGER_TYPES = [:int8, :int16, :int32, :int64,
                   :uint8, :uint16, :uint32, :uint64].freeze
  Ractor.make_shareable(INTEGER_TYPES)
  private_constant :INTEGER_TYPES

  # @!visibility private
  DEFAULT_AXIS_NAME = "row"
  Ractor.make_shareable(DEFAULT_AXIS_NAME)

  # Build a frame from a Hash of +name => column+. Columns may be CArrays or
  # anything that answers +to_ca+ (Ruby Array, lazy view). All columns must
  # share axis-0 length N.
  #
  # The column hash may be passed either explicitly (+CAFrame.new(hash,
  # axis_name: ...)+) or as bare inline pairs (+CAFrame.new("a" => x, "b" =>
  # y)+). +:axis_name+ / +:index+ are control options; any remaining
  # (string-keyed) options are treated as columns.
  #
  # Column names are Strings, in an explicit column hash as in inline pairs.
  # A stray Symbol among the keywords is a mistyped control option
  # (+:axis_name+ / +:index+), not a column, and is named as such.
  #
  # +types:+ casts the built frame as +from_records+ does: it takes anything
  # +cast+ takes as a map (a name => type map, :infer, or a map with
  # +default:+), with +on_error:+ as for +cast+. A cast column is a new array,
  # so a CArray given for it is no longer shared with the frame.
  def initialize(columns = {}, **opts)
    axis_name = opts.delete(:axis_name)
    index     = opts.delete(:index)
    attrs     = opts.delete(:attrs)
    types     = opts.delete(:types)
    on_error  = opts.key?(:on_error) ? opts.delete(:on_error) : :mask
    opts.each_key do |k|
      CAFrame.__send__(:column_key, k, "CAFrame.new",
                       hint: "axis_name:, index:, attrs:, types: and on_error: are the options")
    end
    @attrs = nil
    unless attrs.nil?
      raise TypeError, "CAFrame.new: attrs: takes a Hash (got #{attrs.class})" unless attrs.is_a?(Hash)
      set_attrs(attrs)
    end
    columns = columns.merge(opts) unless opts.empty?

    @columns   = {}
    @axis_name = axis_name.nil? ? DEFAULT_AXIS_NAME :
                   CAFrame.__send__(:column_key, axis_name, "CAFrame.new", "axis_name:")
    @index     = nil
    # The row axis name this frame had before set_index promoted a column over
    # it, so reset_index can put it back.  A frame built with an index never
    # had one, and neither does a frame derived from an indexed one: both are
    # born indexed, so there is nothing to restore and the default stands.
    @axis_name_before_index = nil

    n = nil
    n_from = nil
    columns.each do |name, col|
      key = column_key(name, "CAFrame.new")
      raise ArgumentError, "CAFrame.new: a column name can not be empty" if key.empty?
      ca  = coerce_column(col)
      len = ca.shape[0]
      if n.nil?
        n      = len
        n_from = key
      elsif len != n
        raise ArgumentError,
              "column #{key.inspect} has axis-0 length #{len}, expected #{n}"
      end
      @columns[key] = ca
    end
    @nrow = n || 0

    if index
      idx = coerce_column(index)
      unless idx.ndim == 1
        raise ArgumentError, "index must be a 1-D column (got ndim #{idx.ndim})"
      end
      if n && idx.shape[0] != n
        # Name the column as well as the index: when the index is the frame's
        # existing one and a column is the new arrival, blaming the index alone
        # points at the side the caller cannot change.
        raise ArgumentError,
              "column #{n_from.inspect} has axis-0 length #{n}, " \
              "but the index has length #{idx.shape[0]}"
      end
      @index = idx
      @nrow  = idx.shape[0] if n.nil?
    end

    # With an index, the row axis is named after it; a column of the same name
    # would shadow the index in +row+ and +reset_index+. Reject the collision at
    # construction so those paths never silently drop one for the other.
    if @index && @columns.key?(@axis_name)
      raise ArgumentError,
            "axis_name #{@axis_name.inspect} collides with a column of the same name"
    end

    cast_in_place(types, on_error: on_error, option_name: :types) unless types.nil?
  end

  # --- df[...] : key type decides the axis (memo §13.2) ------------------

  # String    -> a column (raw CArray, the escape unit)
  # String x2+ -> Array<CArray> (the escape unit, plural)
  # Integer   -> a row (Ruby Hash)
  # Range(int)-> positional row slice (view-frame)
  # boolean CA-> row filter (view-frame)
  # integer CA-> row gather (view-frame)
  #
  # String keys escape: df[...] hands back the raw column(s), never a frame.
  # One name collapses to a bare CArray; several give an Array of them (the
  # "single collapses, plural is an array" rule of ca[i] vs ca[i..j]), so
  # +t, rh = df["temp", "rh"]+ destructures. A column-subset *frame* comes
  # from +select+ (memo §13.2).
  def [](*keys)
    if keys.size > 1
      unless keys.all? { |k| k.is_a?(String) }
        raise ArgumentError,
              "df[...] with several keys returns columns; every key must be a String " \
              "(use df.select(...) for a subset frame)"
      end
      return keys.map { |k| @columns.fetch(k) { refuse_missing_column(k) } }
    end

    key = keys.first
    case key
    when String
      @columns.fetch(key) { refuse_missing_column(key) }
    when Integer
      row(key)
    when Range
      unless positional_range?(key)
        raise ArgumentError,
              "df[range] takes positional (integer) ranges only; " \
              "use filter { |f| f.index ... } for label ranges"
      end
      select_rows(key)
    when CArray
      case key.data_type
      when :boolean
        select_rows(key)
      when *INTEGER_TYPES
        select_rows(key)
      else
        raise ArgumentError,
              "CArray df[] key must be boolean or integer (got #{key.data_type})"
      end
    when Symbol
      raise ArgumentError,
            "df[symbol] is reserved for predicate keys; name a column with a String: " \
            "df[#{key.to_s.inspect}]"
    when Array
      refuse_array_key(key)
    else
      raise ArgumentError, "unsupported df[] key: #{key.class}"
    end
  end

  # A Ruby Array is no df[] key, read or written: CArray reads one as
  # [start, count], where [0, 2] would be rows 0 and 1 rather than rows 0
  # and 2. Says what to write for what the Array holds.
  private def refuse_array_key(key, verb = "df[]")
    strings = !key.empty? && key.all? { |k| k.is_a?(String) }
    hint = if strings && verb == "df[]"
             "for columns, df[#{key.map(&:inspect).join(', ')}] or " \
             "df.select(#{key.map(&:inspect).join(', ')})"
           elsif strings
             "a column is named by one String, df[#{key.first.inspect}] = ..."
           elsif !key.empty? && key.all? { |k| k == true || k == false }
             "for rows, a boolean CArray: df[CA_BOOLEAN(#{key.inspect})]"
           else
             "for rows, an integer CArray: df[CA_INT64(#{key.inspect})] " \
             "(a Range picks a run of rows: df[0..2])"
           end
    raise ArgumentError, "#{verb} takes no Ruby Array; #{hint}"
  end

  # --- df[...] = value : row-level assignment ---------------------------
  #
  # The RHS value decides the operation; the key selects the rows:
  #
  #   df[sel] = UNDEF  -> mask the selected rows across every column, in place.
  #                       Shape is unchanged and the write goes through to the
  #                       column storage; the index stays, so the rows remain
  #                       identifiable.
  #   df[sel] = nil    -> delete the selected rows. The frame shrinks and the
  #                       survivors keep their order.
  #   df[sel] = other  -> splice: replace the selected (contiguous) rows with
  #                       +other+'s rows. +other+ may carry any number of rows,
  #                       so the row count changes (Ruby Array#[]= splice
  #                       semantics); its column set must match exactly.
  #
  # +sel+ is a row-axis indexer key, classified exactly as CArray classifies a
  # 1-D column key (docs/topics/Indexer_decision_tree.md): a slice (BLOCK —
  # Range / ArithmeticSequence), a boolean CArray (SELECT), an integer CArray
  # (GRID), or an Integer (a single row). A Ruby Array, which the column
  # indexer would read as [start, count], is refused, as df[] refuses it.
  # Mask and delete take the others and are forwarded to the column indexer,
  # so their errors match the rest of CArray. Splice reuses the same
  # classifier (CArray.scan_index) but needs a contiguous slice, so it takes
  # an Integer or a step-1 BLOCK (Range, step-1 ArithmeticSequence); a
  # strided or scattered selector raises.
  #
  # Delete and splice rebuild the column set, so an alias previously taken
  # from this frame no longer tracks the frame's new column identity
  # (@columns is rebound to a fresh Hash).  Reads through the old alias see
  # the ORIGINAL column's data (unchanged by splice construction), matching
  # the pre-splice snapshot.  Writes flow along the CAMeld chain:
  #
  # - Writes reaching the HEAD or TAIL segment (the parts of the original
  #   column that survived the splice) land back in that column's storage.
  #   External aliases into the original column see those writes — this is
  #   the chain composability that CAMeld deliberately preserves: a
  #   reference stays connected to what it references.
  # - Writes reaching the spliced MIDDLE segment (the rows from +other+)
  #   do NOT reach +other+'s storage: +other+ is snapshotted via +.copy+
  #   at splice time so it behaves like a value that was handed over.
  #   +df1[...] = df2+ followed by writes to df1's spliced rows leaves
  #   df2 untouched, which matches the usual "assignment" intuition for
  #   the RHS of +[]=+.
  #
  # Callers who want write isolation on the head/tail segments too can
  # materialise explicitly with +col_view.copy+ before the splice, or
  # +df["c"] = df["c"].copy+ afterwards.  The shape-preserving +UNDEF+
  # write path always propagates to derived views (unchanged from
  # previous behaviour).
  def []=(*keys, value)
    refuse_if_frozen
    if keys.size != 1
      raise ArgumentError,
            "df[...] = takes one key (a column name or a row selector); " \
            "got #{keys.size}"
    end
    selector = keys.first

    # The key picks the axis, exactly as it does when reading (§13.2): a
    # String names a column, anything else selects rows.
    if selector.is_a?(String)
      column_assign(selector, value)
    elsif selector.is_a?(Array)
      refuse_array_key(selector, "df[] =")
    elsif UNDEF.equal?(value)
      mask_rows(selector)
    elsif value.nil?
      delete_rows(selector)
    elsif value.is_a?(CAFrame)
      splice_rows(selector, value)
    else
      raise ArgumentError,
            "df[...] = expects UNDEF (mask rows), nil (delete rows), or a " \
            "CAFrame (splice rows); got #{value.class}"
    end
    value
  end

  # Freezing a frame fixes its columns, rows and index; the columns' cells are
  # their own arrays' to guard, as an Array's elements are.  The check comes
  # first so a refused edit leaves the frame as it was: the edits change the
  # column table before any instance variable.
  private def refuse_if_frozen
    return unless frozen?
    # The size, not the table: inspect prints every row.
    size = "#{@nrow} row#{@nrow == 1 ? "" : "s"}, #{ncol} column#{ncol == 1 ? "" : "s"}"
    raise FrozenError.new("can't modify frozen CAFrame (#{size})",
                          receiver: self)
  end

  # Make this frame read-only and return it.  It is +freeze+ extended to the
  # cells: the column set, the rows and the index are fixed as by +freeze+,
  # and the cells and masks of every column and of the index refuse writes
  # made through this frame.
  #
  # Each column (and the index) is replaced by a read-only view of itself, so
  # the arrays the frame was built from are left as they were: whoever holds
  # them can still write, and the writes show through this frame.  Frames
  # derived from a protected frame by views (+select+, +filter+, a row slice)
  # read through those views and refuse cell writes too, but are not frozen.
  # +copy+ gives a frame that can be written again.
  #
  # Calling it on a protected frame returns the frame unchanged.  A frame
  # frozen with +freeze+ cannot be protected afterwards, because its columns
  # can no longer be replaced: raises +FrozenError+.
  def protect
    return self if protected?
    refuse_if_frozen
    @columns = @columns.transform_values { |col| read_only_view(col) }
    @index   = read_only_view(@index) if @index
    @protected = true
    freeze
  end

  # True if this frame was made read-only by +protect+.  A +dup+ is not frozen
  # and so not protected, though its columns stay the read-only views it
  # shares; a +clone+ keeps both.
  def protected?
    frozen? && @protected == true
  end

  private def read_only_view(col)
    return col if col.read_only?
    view = col.refer
    view.set_read_only_flag
    view
  end

  # df["name"] = ... : the column forms of []=.  Unlike the verbs, +[]=+ can
  # only ever mutate the receiver -- Ruby hands the right-hand side back as
  # the value of an assignment, so there is no way to return a new frame.
  # Membership is per-frame (§12-B), so a parent frame's column set is
  # untouched.
  #
  #   df["temp"] = col     -> bind the name to that column (a new name is added)
  #   df["unit"] = "degC"  -> a column holding that one value on every row,
  #                           typed as a record's value is (from_records)
  #   df["temp"] = nil     -> remove the column
  #   df["temp"] = UNDEF   -> mask every cell of the column, in place
  private def column_assign(key, value)
    if value.nil?
      delete_column(key)
    elsif UNDEF.equal?(value)
      mask_column(key)
    elsif value.is_a?(CAFrame)
      raise ArgumentError,
            "df[name] = takes a column, not a CAFrame; take one with " \
            "other[\"name\"], or splice rows with df[rows] = other"
    elsif one_value?(value)
      if @columns.empty? && @index.nil?
        raise ArgumentError,
              "df[#{key.inspect}] = #{value.inspect}: the frame has no rows to repeat " \
              "the value on yet; give a column (a CArray or an Array)"
      end
      # Typed from the one value, so a frame with no rows gets the type a
      # frame with rows gets.
      one = CAFrame.__send__(:build_record_column, [value], 1)
      rebind_column(key, one[CArray.int64(@nrow).fill(0), *([nil] * (one.ndim - 1))].copy)
    else
      rebind_column(key, value)
    end
  end

  # A value that is not a column: neither an Array nor anything that turns
  # into a CArray.
  private def one_value?(value)
    return !value.is_a?(Array) && !value.is_a?(CArray) && !value.respond_to?(:to_ca)
  end

  # Bind +key+ to +column+, adding the name when it is new.  This is where a
  # column arriving from outside the frame has its axis-0 length checked
  # (§12-A); the conversions in verbs.rb rebind +@columns+ directly and rely on
  # being length-preserving instead.  It is a replacement rather than an edit,
  # which is what sets it apart from the rest: +fill+ / +mask_eq+ /
  # +df[rows] = UNDEF+ write to the shared column and are therefore visible
  # wherever it is held, while this binds the name to a different column and
  # leaves the old one alone (the same rule +cast+ follows, for the physical
  # reason that a type change cannot reuse the buffer).
  private def rebind_column(key, column)
    raise ArgumentError, "df[name] =: a column name can not be empty" if key.empty?
    if @index && key == @axis_name
      raise ArgumentError,
            "#{key.inspect} names the index, not a column; " \
            "use set_index / reset_index to change the index"
    end
    ca  = coerce_column(column)
    len = ca.shape[0]
    if @columns.empty? && @index.nil? && @nrow.zero?
      @nrow = len                       # the first column of an empty frame fixes N
    elsif len != @nrow
      raise ArgumentError,
            "column #{key.inspect} has axis-0 length #{len}, expected #{@nrow}"
    end
    @columns[key] = ca
  end

  # Remove a column.  +drop+ is the same edit as a new frame (§3.8); this is
  # the in-place form, which is all an assignment can be.
  private def delete_column(key)
    refuse_missing_column(key) unless @columns.key?(key)
    @columns.delete(key)
    @nrow = 0 if @columns.empty? && @index.nil?
    self
  end

  # Mask every cell of a column, in place.  The row form (+df[rows] = UNDEF+)
  # masks the selected rows across every column; this is its column-wise
  # counterpart, and like it the write goes through to the stored column and
  # is visible through every alias.
  private def mask_column(key)
    col = @columns.fetch(key) { refuse_missing_column(key) }
    col[] = UNDEF
    self
  end

  # The names that the arguments of select / drop / transform pick: a name,
  # a Range or Regexp expanded as stack_columns expands it, or a Symbol for
  # the columns of a kind (columns_of_kind); none twice.
  private def names_selected(args, verb)
    names = args.flat_map do |a|
      case a
      when Range, Regexp then columns_selected(a, verb)
      when Symbol        then columns_of_kind(a, verb)
      when Array         then names_selected(a, verb)
      else                    [a]
      end
    end
    return column_keys(names, verb)
  end

  # The names of the columns of a kind, in the frame's order:
  #   :numeric      numbers (CArray#numeric?: integers, floats, complex)
  #   :string       text: CAString, CAConstString, CAFixlenString, or an
  #                 object column whose present cells are all Strings
  #   :time         CATime
  #   :timedelta    CATimedelta
  #   :categorical  CACategorical
  # or a data type as cast names it (:float64, :int32, :boolean, ...), which
  # picks the columns of that type that are not a Face.
  private def columns_of_kind(kind, verb)
    matches =
      case kind
      when :numeric     then ->(col) { col.numeric? }
      when :string      then ->(col) { string_kind_column?(col) }
      when :time        then ->(col) { col.is_a?(CATime) }
      when :timedelta   then ->(col) { col.is_a?(CATimedelta) }
      when :categorical then ->(col) { col.is_a?(CACategorical) }
      else
        # A Symbol that is neither is a column name written as a Symbol.
        name = begin
                 CArray.data_type_name(kind)
               rescue ArgumentError, TypeError, CArray::DataTypeError
                 CAFrame.__send__(:column_key, kind, verb,
                                  hint: "a Symbol names a kind of column (:numeric, :string, " \
                                        ":time, :timedelta, :categorical) or a data type")
               end
        ->(col) { !col.face? && CArray.data_type_name(col.data_type) == name }
      end
    names = @columns.keys.select { |key| matches.(@columns[key]) }
    raise ArgumentError, "#{verb}: #{kind.inspect} selects no column" if names.empty?
    return names
  end

  # A column of text: a string Face, or an object column whose present
  # cells are all Strings (one with none present is not).
  private def string_kind_column?(col)
    return true if col.is_a?(CArray::StringOperationMixin)
    return false if col.face? || col.data_type != :object
    found = false
    col.each do |v|
      next if UNDEF.equal?(v)
      return false unless v.is_a?(String)
      found = true
    end
    return found
  end

  # Column projection (memo §13.2): a view-frame holding the named columns as
  # aliases (zero-copy, sharing storage with the parent frame). Distinct from
  # +df[...]+, which escapes columns to raw CArrays, and from +filter+, which
  # selects rows. +select+ takes no block — row conditions go through +filter+
  # (old carray-dataframe fused the two into +select(cols) { cond }+; here they
  # are orthogonal and compose by chaining: +df.select(...).filter { ... }+).
  # Each argument is a name, a Range of names (the columns from one to the
  # other, in the frame's order) or a Regexp (the names it matches), as
  # +stack_columns+ takes them.
  #
  #   df.select("station", "tmax".."rain")
  #   df.select(/^t/)
  def select(*names)
    raise ArgumentError, "select requires at least one column name" if names.empty?
    cols = {}
    names_selected(names, "select").each do |key|
      refuse_missing_column(key) unless @columns.key?(key)
      cols[key] = @columns[key]
    end
    rebuild(cols)
  end

  # Keep the rows where a boolean selector is true. The selector is given
  # directly (+df.filter(df["temp"] > 0)+), or built by a block that receives
  # the frame (+df.filter { |f| f["temp"] > 0 }+), from +f["col"]+ /
  # +f.index+. Give one or the other, not both.
  #
  # Combine conditions with +&+ / +|+ (or +.and+ / +.or+, which leave a row
  # undetermined when either side is masked) and negate with +.not+. Ruby's
  # +&&+ / +||+ look only at whether the left array exists, so +a && b+ is +b+
  # and the first condition is silently dropped.
  #
  # A masked (UNDEF) selector cell means the row's membership is undetermined
  # (e.g. the predicate read a masked input). Such a row is not kept, as a
  # false cell is not, as +ca[selector]+ does. Settle it in the selector to
  # choose otherwise: +s.is_masked+ selects the undetermined rows,
  # +s.strip_mask(true)+ keeps them along with the true ones.
  #
  # The result is a sub-frame of views sharing the frame's cells.
  def filter(*selector, **options)
    CAFrame.__send__(:refuse_filter_keywords, options, "filter")
    if selector.size > 1
      raise ArgumentError, "filter takes one selector (got #{selector.size})"
    end
    if selector.empty?
      unless block_given?
        raise ArgumentError, "filter needs a boolean selector or a block"
      end
      mask = yield(self)
      given = "filter block must return"
    else
      if block_given?
        raise ArgumentError, "filter takes a selector or a block, not both"
      end
      mask = selector.first
      given = "filter selector must be"
    end
    unless mask.is_a?(CArray) && mask.data_type == :boolean
      raise ArgumentError,
            "#{given} a boolean CArray (got #{mask.is_a?(CArray) ? "a #{CArray::Inspector.type_label(mask)} CArray" : mask.class})" +
            CAFrame.__send__(:equality_hint, mask)
    end
    unless mask.shape == [@nrow]
      raise ArgumentError,
            "filter mask has shape #{mask.shape.inspect}, expected [#{@nrow}] (one value per row)"
    end
    select_rows(mask)
  end

  # Keep the rows that have no masked cell in the named columns (every
  # column when none is named), as a sub-frame of views, as +filter+ returns.
  # A cell of an N-D column masks its row. The index is a column here only
  # when named, by the row axis name. A NaN is a value, not a masked cell:
  # mask it first (+df["x"][:is_invalid] = UNDEF+) to drop its row too.
  #
  #   df.drop_masked                    # rows complete in every column
  #   df.drop_masked("tmax", "tmin")    # rows with both temperatures
  #
  # @param names [Array<String, Range, Regexp, Symbol>] the columns to look
  #   at, picked as +select+ picks them.
  # @return [CAFrame]
  # @raise [KeyError] for a name that is no column.
  def drop_masked (*names)
    keys = names.empty? ? @columns.keys : names_selected(names, "drop_masked")
    holes = CArray.boolean(@nrow).fill(false)
    keys.each do |key|
      col = if @columns.key?(key)
              @columns[key]
            elsif @index && key == @axis_name
              @index
            else
              refuse_missing_column(key)
            end
      masked = col.is_masked
      masked = masked.any(axis: (1...masked.ndim).to_a) if masked.ndim > 1
      holes |= masked
    end
    return select_rows(holes.not)
  end

  # Judge every row against named rules, and return the verdicts as a frame:
  #
  #   report = df.verify(
  #     "age is not negative" => ->(f) { f["age"] >= 0 },
  #     "end after start"     => ->(f) { f["end"] > f["start"] },
  #   )
  #   df.filter { |f| report["end after start"].not }   # the rows that break it
  #
  # A rule is called with the frame, as a +filter+ block is, and returns a
  # boolean CArray with one entry per row on its first axis; true means the
  # rule holds.  A rule over an N-D column may answer per cell, in the
  # column's own shape, so the cells that break it can be masked directly.
  # A cell the rule could not judge -- it read a masked value -- stays
  # UNDEF rather than becoming false.
  #
  # The result has one column per rule, named after it, and this frame's
  # index and row axis name.
  #
  # @param rules [Hash{String => #call}] the rules by name.
  # @return [CAFrame]
  # @raise [ArgumentError] when there are no rules, a name is empty, or a
  #   rule does not return a boolean CArray of this frame's length.
  # @raise [TypeError] when a name is not a String.
  def verify(rules)
    unless rules.is_a?(Hash)
      raise ArgumentError, "verify: the rules are a Hash of name => rule (got #{rules.class})"
    end
    raise ArgumentError, "verify: there are no rules" if rules.empty?
    verdicts = {}
    rules.each do |name, rule|
      key = column_name_arg(name, "verify")
      if @index && key == @axis_name
        raise ArgumentError,
              "verify: rule #{key.inspect} has the name of the row axis, " \
              "which the index has in the result; name the rule otherwise"
      end
      unless rule.respond_to?(:call)
        raise ArgumentError, "verify: rule #{key.inspect} is not callable (got #{rule.class})"
      end
      verdict = rule.call(self)
      unless verdict.is_a?(CArray) && verdict.data_type == :boolean
        raise ArgumentError,
              "verify: rule #{key.inspect} must return a boolean CArray (got " \
              "#{verdict.is_a?(CArray) ? "a #{verdict.data_type} CArray" : verdict.class})" +
              CAFrame.__send__(:equality_hint, verdict)
      end
      unless verdict.shape[0] == @nrow
        raise ArgumentError,
              "verify: rule #{key.inspect} returned shape #{verdict.shape.inspect}, " \
              "expected #{@nrow} rows on the first axis"
      end
      verdicts[key] = verdict
    end
    # The verdicts are a table about the rows, not a part of this one, so the
    # frame's attributes are not carried.
    CAFrame.new(verdicts, axis_name: @axis_name, index: @index)
  end

  # A new frame with a column moved to the index and the row axis named
  # after it (memo §3); this frame is left as it is, and the two share their
  # columns. Any existing index is replaced, going back to being a column.
  def set_index(name)
    return dup.__send__(:set_index_in_place, name)
  end

  private def set_index_in_place(name)
    refuse_if_frozen
    key = column_key(name, "set_index")
    refuse_missing_column(key) unless @columns.key?(key)
    idx = @columns[key]
    unless idx.ndim == 1
      raise ArgumentError, "index must be a 1-D column (got ndim #{idx.ndim})"
    end
    # Only the name held before the frame had an index: a second set_index must
    # not overwrite it with the first index's name.
    @axis_name_before_index = @axis_name if @index.nil?
    @columns.delete(key)
    if @index
      # Re-indexing replaces the index, so the one being replaced goes back to
      # being a column -- the same demotion reset_index performs, in the same
      # position, which makes set_index over an existing index equivalent to
      # reset_index followed by set_index.  Dropping it would lose the column it
      # was made from.
      @columns = { @axis_name => @index }.merge(@columns)
    end
    @index     = idx
    @axis_name = key
    @nrow      = idx.shape[0]
    self
  end

  # A new frame with the index back as an ordinary column (the inverse of
  # set_index); this frame is left as it is. The former index becomes the
  # first column, named after the row axis.
  def reset_index
    return dup.__send__(:reset_index_in_place)
  end

  private def reset_index_in_place
    refuse_if_frozen
    return self unless @index
    @columns   = { @axis_name => @index }.merge(@columns)
    @index     = nil
    @axis_name = @axis_name_before_index || DEFAULT_AXIS_NAME
    @axis_name_before_index = nil
    self
  end

  # The first +n+ rows as a positional view-frame (memo §11.3). +n+ larger
  # than +nrow+ yields the whole frame; +n+ of 0 yields an empty frame.
  def head(n = 5)
    raise ArgumentError, "head count must be non-negative (got #{n})" if n < 0
    row_span(0, [n, @nrow].min)
  end

  # The last +n+ rows as a positional view-frame (memo §11.3). +n+ larger
  # than +nrow+ yields the whole frame; +n+ of 0 yields an empty frame.
  def tail(n = 5)
    raise ArgumentError, "tail count must be non-negative (got #{n})" if n < 0
    row_span(@nrow - [n, @nrow].min, @nrow)
  end

  # The single row whose index label equals +label+, as a Ruby Hash (memo
  # §13.2b). +label+ is matched exactly against the index (+index.eq+), so any
  # orderable / object / datetime / categorical index works, and +label+ is
  # whatever +index.eq+ takes -- for a time index, a Time, Date or a String
  # such as "2024-01-02".  A NaN label finds the NaN label, as join and
  # group_by match NaN keys.  A numeric index takes a number; a String or
  # true / false raises. The return type is
  # a row Hash and stays that way: zero matches raise KeyError, and duplicate
  # labels raise (go through +filter { |f| f.index.eq(label) }+ for the
  # multi-row, frame-returning path). Positional access is +df[i]+.
  def at(label)
    raise ArgumentError, "at requires an index (set one with set_index)" unless @index
    # An index may hold a masked cell -- an outer join and align both build one
    # -- but an undefined label identifies no row, and two undefined labels are
    # not the same label. The addressing primitives already say this (a masked
    # key matches nothing, not another masked key), so at says it too rather
    # than answering through eq(UNDEF), which asks about the mask and not about
    # the label at all.
    if UNDEF.equal?(label)
      raise ArgumentError,
            "at(UNDEF): an undefined label identifies no row; " \
            "use filter { |f| f.index.is_masked } for the rows with no label"
    end
    # A NaN label is the NaN value, as join and group_by take it: eq answers
    # false for NaN against anything, itself included.
    # A numeric index is looked up with a number: a String or true/false would
    # be read differently by each numeric type, or not at all.
    if !@index.face? && (@index.integer? || @index.float? || @index.complex?) &&
       !label.is_a?(Numeric)
      raise ArgumentError,
            "at: the index is #{@index.data_type}, so the label must be a number " \
            "(got #{label.inspect}); convert it first, e.g. at(Float(s)) or at(Integer(s))"
    end
    nan = label.is_a?(Float) && label.nan?
    hit = nan ? @index.is_in([label]) : @index.eq(label)
    pos = hit.where
    case pos.elements
    when 0
      raise KeyError, "no row with index label #{label.inspect}"
    when 1
      row(pos[0])
    else
      test = nan ? "f.index.is_nan" : "f.index.eq(label)"
      raise ArgumentError,
            "index label #{label.inspect} matches #{pos.elements} rows; " \
            "use filter { |f| #{test} } for duplicate labels"
    end
  end

  # An independent frame — every column and the index materialized (§3.6).
  def copy
    cols = {}
    @columns.each { |k, v| cols[k] = v.copy }
    CAFrame.new(cols, axis_name: @axis_name, index: @index && @index.copy,
                attrs: @attrs)
  end

  # Whether +other+ is a frame holding the same table: the same column names
  # in the same order, each column equal as CArray#== has it (data type,
  # shape, the present values and where the cells are masked), and the same
  # index and row axis name. Attributes are not compared.
  #
  # @param other [Object]
  # @return [Boolean]
  def == (other)
    return true if equal?(other)
    return false unless other.is_a?(CAFrame)
    return false unless column_names == other.column_names && @axis_name == other.axis_name
    return false unless @nrow == other.nrow
    if @index.nil? || other.index.nil?
      return false unless @index.nil? && other.index.nil?
    else
      return false unless @index == other.index
    end
    return @columns.all? { |name, col| col.shape == other[name].shape && col == other[name] }
  end

  # A key value as an error message shows it: a String quoted, an element of
  # a Face (a time, say) as it reads.
  def self.key_text (value)
    return value.inspect if value.is_a?(String) || value.is_a?(Numeric) || value.nil?
    return value.to_s if value.class.name.to_s.end_with?("::Element")
    return value.inspect
  end
  private_class_method :key_text

  # +dup+ / +clone+ share the column data -- that is the CArray dup contract
  # (§3.6) -- but must not share the columns Hash itself: Ruby's shallow copy
  # hands over the same Hash object, so a membership edit (+append+ / +drop+ /
  # a +cast+ rebind) on the copy would show up in the original, which is the
  # one thing per-frame membership (§12-B) says never happens.
  private def initialize_copy(other)
    super
    @columns = @columns.dup
    @attrs   = @attrs.dup if @attrs
    @name_views = nil
  end

  # Marshal writes the instance variables as they are.  Loading stores the
  # attribute values again as set_attr does, as frozen copies: Marshal
  # brings back a value thawed.
  private def marshal_dump
    (instance_variables - [:@name_views]).to_h { |name| [name, instance_variable_get(name)] }
  end

  private def marshal_load(ivars)
    ivars.each { |name, value| instance_variable_set(name, value) }
    if @attrs
      @attrs = @attrs.transform_values { |v| CArray.__send__(:attr_coerce_value, v) }
    end
  end

  # --- attributes of the frame ------------------------------------------
  #
  # Key/value metadata about the table as a whole (a title, a source), apart
  # from each column's own attributes.  Keys and values follow the rules of
  # CArray#set_attr: a Symbol or String key, stored as a String, and a
  # JSON-compatible value, stored as a frozen copy.
  #
  # A frame made from this one takes its attributes when it holds the same
  # table: a selection of rows (df[rows], filter, head, tail, sort_by,
  # join(how: :semi / :anti)), a change of columns (select, append, drop,
  # rename, ...), copy and dup.  A frame computed from it -- a summary, a
  # join, a reshape -- does not; ask the frame it came from.  Each frame has
  # its own Hash: setting an attribute on a frame made from this one leaves
  # this one unchanged.

  # The value of the attribute +key+, or nil when the frame has none.
  def attr(key)
    @attrs ? @attrs[CArray.__send__(:attr_normalize_key, key)] : nil
  end

  # Set the attribute +key+ to +value+ and return the stored value.
  def set_attr(key, value)
    refuse_if_frozen
    CArray.__send__(:attr_validate_value, value)
    (@attrs ||= {})[CArray.__send__(:attr_normalize_key, key)] =
      CArray.__send__(:attr_coerce_value, value)
  end

  # Set every key of +hash+, as set_attr sets one, and return self.  Every
  # value is checked before any is written.
  def set_attrs(hash)
    refuse_if_frozen
    raise TypeError, "set_attrs takes a Hash (got #{hash.class})" unless hash.is_a?(Hash)
    entries = hash.map do |key, value|
      CArray.__send__(:attr_validate_value, value)
      [CArray.__send__(:attr_normalize_key, key), CArray.__send__(:attr_coerce_value, value)]
    end
    unless entries.empty?
      h = (@attrs ||= {})
      entries.each { |k, v| h[k] = v }
    end
    self
  end

  # Remove the attribute +key+ and return its value, or nil.
  def delete_attr(key)
    k = CArray.__send__(:attr_normalize_key, key)
    return nil unless @attrs&.key?(k)
    refuse_if_frozen
    @attrs.delete(k)
  end

  # A frozen Hash of the frame's attributes.
  def attrs
    (@attrs ? @attrs.dup : {}).freeze
  end

  # The frame's attributes with Symbol keys, frozen.  The keys of Hashes
  # nested in the values become Symbols as well.
  def attrs_symkey
    CArray.__send__(:attr_symbolize_keys, attrs)
  end

  # Set attributes on columns and return self.  The columns are the ones
  # named, or every column when none is named.  With attributes, they are
  # set on those columns; with none, each column gets its own name as the
  # attribute "name", which is what the frame knows of a column and a column
  # taken out of it does not:
  #
  #   df.set_column_attrs                                # "name" on every column
  #   df.set_column_attrs(period: "I")                   # period on every column
  #   df.set_column_attrs(df.attrs)                      # the frame's attributes
  #   df.set_column_attrs("hr", long_name: "Hour")       # long_name on "hr"
  #   df.set_column_attrs("hr", "cnt", station: "A")     # station on both
  #
  # The attributes come as keywords, as a Hash given last, or both; an empty
  # Hash sets nothing (df.set_column_attrs(df.attrs) on a frame with no
  # attributes does not set "name").  Keys and values follow
  # CArray#set_attrs.  A column's other attributes are kept, and the index
  # is not a column.  A column is named once.  Every name, key, value and
  # column is checked before any is written.  The attributes belong to the
  # columns, not the table, so a frozen or protected frame takes them; a
  # frozen column refuses them.
  #
  # Attributes given are set on the column arrays themselves, so frames that
  # share a column (select, rename, append, drop, paste and dup share them)
  # all see them, as they all see its cells.  A name is not about the data
  # but about this frame, so it is not set on the shared array: the column
  # is replaced by a view of it (+refer+, the same data, Face and mask) that
  # carries the name, and the array's other attributes still show through
  # it.  Each frame names its own view, whatever order frames are named in,
  # and a frame that names nothing shows no name.  Giving names replaces
  # columns, so a frozen frame refuses it unless every column named already
  # is this frame's own named view.
  def set_column_attrs(*names, **keywords)
    given = names.last.is_a?(Hash) || !keywords.empty?
    attrs = names.last.is_a?(Hash) ? names.pop.merge(keywords) : keywords
    targets = names.empty? ? @columns.keys : column_keys(names, "set_column_attrs")
    columns = targets.map { |name| @columns.fetch(name) { refuse_missing_column(name, "set_column_attrs") } }
    attrs.each do |key, value|
      CArray.__send__(:attr_normalize_key, key)
      CArray.__send__(:attr_validate_value, value)
    end
    columns.each { |col| col.__send__(:attr_check_writable) }
    if given
      # On the arrays the names were put in front of, so every frame
      # sharing the data sees them.
      columns.each { |col| CAFrame.__send__(:named_source, col).set_attrs(attrs) }
      return self
    end
    own = @name_views || {}
    reuse = targets.zip(columns).map do |name, col|
      own.key?(col) && @columns.count { |_, c| c.equal?(col) } == 1
    end
    if frozen? && !reuse.all?
      raise FrozenError.new("set_column_attrs: a name goes on a view of the column that " \
                            "replaces it in this frame, and a frozen CAFrame keeps its " \
                            "columns; name the columns before freezing, or name a copy",
                            receiver: self)
    end
    targets.zip(columns, reuse).each do |name, col, same|
      view = same ? col : CAFrame.__send__(:name_view, col)
      (@name_views ||= {}.compare_by_identity)[view] = true
      @columns[name] = view
      view.set_attr("name", name)
    end
    self
  end

  # A view of +col+ to carry a frame's name for it: the same data, Face and
  # mask, with the column's other attributes showing through. It remembers
  # the column it was made from (named_source).
  def self.name_view(col)
    view = col.refer
    view.instance_variable_set(:@named_source, named_source(col))
    view
  end
  private_class_method :name_view

  # The array a name view was made from, or +col+ itself.
  def self.named_source(col)
    col.instance_variable_get(:@named_source) || col
  end
  private_class_method :named_source

  # Whether the frame has any attribute, or the attribute +key+.
  def has_attr?(key = nil)
    return !(@attrs.nil? || @attrs.empty?) if key.nil?
    !!@attrs&.key?(CArray.__send__(:attr_normalize_key, key))
  end

  # --- metadata readers (memo §13.2) ------------------------------------
  # Each returns a fresh object; the live columns Hash is never exposed.

  # Column names in column order.  Returns +Array<String>+.
  def column_names
    @columns.keys
  end

  # The columns (raw CArrays) in column order.  Returns +Array<CArray>+.
  # Equivalent to +df[*column_names]+ but built directly from the columns
  # Hash.
  def columns
    @columns.values
  end

  # Number of columns.
  def ncol
    @columns.size
  end

  # [nrow, ncol]. The index is not a column, so it is not counted.
  def shape
    return [@nrow, @columns.size]
  end

  # Whether the frame has no rows.
  def empty?
    return @nrow == 0
  end

  # Number of rows (axis-0 length N).
  attr_reader :nrow

  # Row-axis name.
  attr_reader :axis_name

  # Index column (CArray) or nil.
  attr_reader :index

  # name => data_type, freshly derived; a Face column gives its class
  # (CATime, CAString, ...), since a Face's data_type is the surface its
  # kernels dispatch on, not what the column holds.
  def data_types
    h = {}
    @columns.each { |k, v| h[k] = v.face? ? v.class : v.data_type }   # type-label: data_types returns the class itself, a value
    h
  end

  # A frame of the same table with a different set of columns: it takes this
  # frame's attributes.
  private def rebuild(cols)
    CAFrame.new(cols, axis_name: @axis_name, index: @index, attrs: @attrs)
  end

  # A column given to the frame: a CArray as it is; a Ruby Array typed by its
  # values as from_records types a record's (build_record_column); anything
  # else through its to_ca.
  private def coerce_column(col)
    if col.is_a?(Array)
      return CAFrame.__send__(:build_record_column, col, col.size)
    end
    if col.is_a?(CAFrame)
      raise ArgumentError,
            "a CAFrame cannot be a column (it answers to_ca as a 2-D matrix); " \
            "take a column with df[\"name\"] or df.to_ca first"
    end
    unless col.respond_to?(:to_ca)
      raise ArgumentError, "column must be a CArray or Array (got #{col.class})"
    end
    ca = col.to_ca
    unless ca.is_a?(CArray)
      raise ArgumentError, "column did not convert to a CArray (got #{ca.class})"
    end
    ca
  end

  private def row(i)
    pos = i < 0 ? i + @nrow : i
    unless pos >= 0 && pos < @nrow
      raise IndexError, "row index #{i} out of range (nrow=#{@nrow})"
    end
    i = pos
    h = {}
    h[@axis_name] = elem_at(@index, i) if @index
    @columns.each { |name, col| h[name] = elem_at(col, i) }
    h
  end

  private def elem_at(col, i)
    col[i, *([nil] * (col.ndim - 1))]
  end

  private def row_span(lo, hi)
    if hi <= lo
      select_rows(CArray.int32(0))
    else
      select_rows(lo...hi)
    end
  end

  # df[sel] = UNDEF : mask the selected rows in place (write-through). Shape
  # and index are untouched; the selected cells of every column go to UNDEF.
  # The selector is forwarded to the column indexer, which classifies it.
  private def mask_rows(selector)
    # Decide before changing anything. A read-only column (a categorical, whose
    # codes are read-only) refuses the write, and refusing half way through
    # would leave the frame masked in whichever columns happened to come first.
    refusing = @columns.find { |_, col| col.read_only? }
    if refusing
      raise "can not modify read-only array: column #{refusing[0].inspect} " \
            "refuses the write, so no column was masked"
    end
    # The selector is classified by the column indexer, which is also what
    # bound-checks it -- so with no column to forward it to, nothing would.
    # Build the row mask purely to have the frame's own row axis refuse an
    # out-of-range row, as every other row form does.
    selected_row_mask(selector) if @columns.empty?
    @columns.each_value do |col|
      col[selector, *([nil] * (col.ndim - 1))] = UNDEF
    end
    self
  end

  # df[sel] = nil : drop the selected rows. The surviving rows are gathered by
  # the complement of the selection (order preserved), and the frame shrinks.
  private def delete_rows(selector)
    keep = selected_row_mask(selector).not
    new_cols = {}
    @columns.each do |name, col|
      new_cols[name] = col[keep, *([nil] * (col.ndim - 1))]
    end
    @columns = new_cols
    @index   = @index[keep] if @index
    @nrow    = keep.count(true)
    self
  end

  # df[sel] = other : replace the selected contiguous span with other's rows
  # (any length). Columns are concatenated head + other + tail, so data types
  # promote and the row count shifts by other.nrow - span.
  private def splice_rows(selector, other)
    lo, hi = contiguous_span(selector)
    unless other.column_names.sort == column_names.sort
      raise ArgumentError,
            "splice frame has columns #{other.column_names.inspect}, " \
            "expected the same set as #{column_names.inspect}"
    end
    new_cols = {}
    @columns.each do |name, col|
      tail   = [nil] * (col.ndim - 1)
      pieces = []
      pieces << col[0...lo, *tail]     if lo > 0
      # Snapshot the RHS: df1[...] = df2 is a value assignment, so subsequent
      # writes to df1's spliced rows must not leak into df2 via the CAMeld
      # chain.  Head / tail slices come from df1 itself and keep the intended
      # chain composability (writes to df1["c"][k] still reach df1's own
      # storage there — external aliases into df1's old column see them).
      pieces << other[name].copy       if other.nrow > 0
      pieces << col[hi...@nrow, *tail] if hi < @nrow
      new_cols[name] =
        case pieces.size
        when 0 then col[CArray.int32(0), *tail]   # replaced every row with none
        when 1 then pieces.first
        else
          # A splice does not promote the column (it would hide schema
          # drift); cast the incoming column beforehand.
          CAFrame.send(:check_same_column_type, pieces, name, verb: "splice")
          CArray.meld(pieces, axis: 0)
        end
      splice_keep_attrs(new_cols[name], col)
    end
    new_index = splice_index(other, lo, hi)
    splice_keep_attrs(new_index, @index) if new_index
    @columns  = new_cols
    @index    = new_index
    # Read the new count off something the frame now holds, rather than
    # computing it. For every column the pieces welded above are head (lo) +
    # other's rows + tail (nrow - hi), so the arithmetic and the objects agree
    # -- except when there is nothing to weld: a frame with no columns and no
    # index would otherwise come away claiming rows that nothing backs.
    @nrow = if (witness = new_cols.each_value.first || new_index)
              witness.shape[0]
            else
              0
            end
    self
  end

  # A splice edits this frame's table, so a spliced column keeps the
  # attributes this frame's column had, whatever the rows put in carry.
  private def splice_keep_attrs(result, own)
    (result.attrs.keys - own.attrs.keys).each { |k| result.delete_attr(k) }
    result.set_attrs(own.attrs)
  end

  # The index for a splice: head + other's index + tail. When this frame has
  # an index, the spliced-in frame must have one too (its rows need labels).
  private def splice_index(other, lo, hi)
    return nil unless @index
    if other.nrow > 0 && other.index.nil?
      raise ArgumentError,
            "splice frame needs an index because the target frame has one"
    end
    pieces = []
    pieces << @index[0...lo]     if lo > 0
    pieces << other.index.copy   if other.nrow > 0   # snapshot RHS (see splice_rows)
    pieces << @index[hi...@nrow] if hi < @nrow
    case pieces.size
    when 0 then @index[CArray.int32(0)]
    when 1 then pieces.first
    else CArray.meld(pieces, axis: 0)   # index data type must match across frames
    end
  end

  # A boolean mask over the rows, true where +selector+ selects. Built by
  # marking a false vector through the same selector the reader accepts, so
  # Range / Integer / boolean / integer-array all normalize the same way.
  private def selected_row_mask(selector)
    m = CArray.boolean(@nrow) { 0 }
    m[selector] = 1
    m
  end

  # Resolve a contiguous span [lo, hi) for splice, reusing the row-axis indexer
  # classifier (CArray.scan_index) so negatives, exclusive ends,
  # ArithmeticSequence and the [start, count(, step)] array forms parse exactly
  # as they do for a column key. Only a POINT (single row) or a step-1 BLOCK
  # (contiguous slice) has a span to replace; a strided or scattered selector
  # raises.
  #
  # The one place splice diverges from element indexing is the tail insertion
  # point: scan_index bound-checks the start to 0..nrow-1, but splice — like
  # Ruby Array#[]= — also accepts nrow as an empty span to append to, written
  # +nrow...nrow+.
  private def contiguous_span(selector)
    if (selector.is_a?(Range) || selector.is_a?(Enumerator::ArithmeticSequence)) &&
       selector.exclude_end? && selector.begin == @nrow && selector.end == @nrow
      return [@nrow, @nrow]
    end

    info = CArray.scan_index([@nrow], [selector])
    case info.type
    when CA_REG_POINT
      i = info.index[0]
      [i, i + 1]
    when CA_REG_BLOCK
      start, count, step = info.index[0]
      unless step == 1
        raise ArgumentError,
              "splice needs a contiguous slice; a strided step #{step} has no span"
      end
      [start, start + count]
    else
      raise ArgumentError,
            "splice (df[...] = frame) needs a contiguous slice (Range, Integer, " \
            "or [start, count]); got #{selector.class}"
    end
  end

  private def select_rows(selector)
    cols = {}
    @columns.each do |name, col|
      cols[name] = col[selector, *([nil] * (col.ndim - 1))]
    end
    new_index = @index ? @index[selector] : nil
    CAFrame.new(cols, axis_name: @axis_name, index: new_index, attrs: @attrs)
  end

  # df["name"] for a name that is no column. The index is not a column, so
  # its name is refused too, pointing at df.index. +verb+, when given, leads
  # the message.
  private def refuse_missing_column(key, verb = nil)
    lead = verb ? "#{verb}: " : ""
    if @index && key == @axis_name
      raise KeyError,
            "#{lead}no column #{key.inspect}: it is the index, read it with df.index " \
            "(reset_index makes it a column again)"
    end
    raise KeyError, "#{lead}no column #{key.inspect}"
  end

  # filter takes no keyword. keep_masked:, which it once took, is named
  # with where its work went: the selector settles an undetermined row.
  def self.refuse_filter_keywords(options, verb)
    return if options.empty?
    names = options.keys.map(&:inspect).join(", ")
    message = "#{verb}: unknown keyword#{options.size > 1 ? "s" : ""} #{names}"
    if options.key?(:keep_masked)
      message += "; to keep the rows whose condition is undetermined, select them " \
                 "in the selector (s.strip_mask(true))"
    end
    raise ArgumentError, message
  end
  private_class_method :refuse_filter_keywords

  # A column name given as an argument: a String, as the frame's column
  # keys are. Symbols are the frame's options and types, never names.
  private def column_key(name, verb)
    CAFrame.__send__(:column_key, name, verb)
  end

  # A name a verb is given for a column -- or, with +what+, for the row
  # axis -- is a String: a Symbol is a frame's option or type, never a
  # name.  Anything else is refused with TypeError "<verb>: <what> is a
  # String (got :x)", +hint+ appended.  A +verb+ that is an option, as
  # "types:", already ends in its colon.
  def self.column_key(name, verb, what = "a column name", hint: nil)
    return name if name.is_a?(String)
    message = "#{verb.end_with?(":") ? verb : "#{verb}:"} #{what} is a String (got #{name.inspect})"
    message += "; #{hint}" if hint
    raise TypeError, message
  end
  private_class_method :column_key

  # A list of column names as a verb takes them: each a String, and none
  # twice.
  private def column_keys(names, verb)
    CAFrame.__send__(:refuse_repeated_names, names.map { |n| column_key(n, verb) }, verb)
  end

  # Column names a verb makes or takes, none of them twice.  A frame holds
  # one column per name, so a repeated name among new columns would keep
  # only the last of them, and among the columns a verb takes would be
  # taken once or twice depending on the verb.  Refused with ArgumentError
  # "<verb>: <what> <name> more than once", +hint+ appended.  df[...] alone
  # takes a name twice, as Hash#values_at does.
  def self.refuse_repeated_names(names, verb, what = "names", hint: nil)
    dup = names.tally.find { |_, count| count > 1 }
    return names unless dup
    message = "#{verb}: #{what} #{dup.first.inspect} more than once"
    message += "; #{hint}" if hint
    raise ArgumentError, message
  end
  private_class_method :refuse_repeated_names

  # A condition that gave true or false rather than a boolean CArray has, as
  # likely as not, compared two arrays whole with == or !=.
  def self.equality_hint(value)
    return "" unless value == true || value == false
    "; == and != compare whole arrays, eq and ne compare cell by cell " \
      "(f[\"x\"].eq(\"a\"))"
  end
  private_class_method :equality_hint

  # percentile(p, *names): the percentage comes first. A name there is the
  # order of median's arguments carried over, said so; a percentage out of
  # range is refused by the core here, before any column is asked whether
  # it has a percentile.
  def self.check_percentage(p)
    unless p.is_a?(Numeric)
      raise ArgumentError,
            "percentile: give the percentage first, then the column names " \
            "(got #{p.inspect}; percentile(90, \"x\"))"
    end
    CArray.float64(1).percentile(p)
  end
  private_class_method :check_percentage

  # The labels an index is made of from a key -- a group's first values,
  # the resample bins, the sorted pivot keys -- as the key column shows
  # them: +labels+, already of the key's data type, Face and unit, given
  # the key's attributes.  Returns +labels+.
  def self.key_labels(key, labels)
    key.__send__(:carry_attrs, labels)
  end
  private_class_method :key_labels

  private def positional_range?(range)
    (range.begin.nil? || range.begin.is_a?(Integer)) &&
      (range.end.nil? || range.end.is_a?(Integer))
  end
end

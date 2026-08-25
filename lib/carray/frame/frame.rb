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
  # Integer data_types that select rows positionally when used as a df[] key.
  INTEGER_TYPES = [:int8, :int16, :int32, :int64,
                   :uint8, :uint16, :uint32, :uint64].freeze
  private_constant :INTEGER_TYPES

  # @!visibility private
  DEFAULT_AXIS_NAME = "row"

  # Build a frame from a Hash of +name => column+. Columns may be CArrays or
  # anything that answers +to_ca+ (Ruby Array, lazy view). All columns must
  # share axis-0 length N.
  #
  # The column hash may be passed either explicitly (+CAFrame.new(hash,
  # axis_name: ...)+) or as bare inline pairs (+CAFrame.new("a" => x, "b" =>
  # y)+). +:axis_name+ / +:index+ are control options; any remaining
  # (string-keyed) options are treated as columns.
  #
  # Column names are normalized to Strings, so a Symbol key in an explicit
  # column hash is stringified. The Symbol rejection below applies only to the
  # keyword channel, which doubles as the +:axis_name+ / +:index+ control-option
  # channel: a stray Symbol there is a mistyped control option, not a column.
  def initialize(columns = {}, **opts)
    axis_name = opts.delete(:axis_name)
    index     = opts.delete(:index)
    stray = opts.keys.reject { |k| k.is_a?(String) }
    unless stray.empty?
      raise ArgumentError,
            "column keys must be Strings (Symbols are reserved); got #{stray.inspect}"
    end
    columns = columns.merge(opts) unless opts.empty?

    @columns   = {}
    @axis_name = axis_name || DEFAULT_AXIS_NAME
    @index     = nil

    n = nil
    columns.each do |name, col|
      key = name.to_s
      ca  = coerce_column(col)
      len = ca.shape[0]
      if n.nil?
        n = len
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
        raise ArgumentError,
              "index length #{idx.shape[0]} does not match nrow #{n}"
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
              "multi-key df[...] escapes columns; every key must be a String " \
              "(use df.select(...) for a subset frame)"
      end
      return keys.map { |k| @columns.fetch(k) { raise KeyError, "no column #{k.inspect}" } }
    end

    key = keys.first
    case key
    when String
      @columns.fetch(key) { raise KeyError, "no column #{key.inspect}" }
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
      raise NotImplementedError, "df[symbol] is reserved for predicate keys"
    else
      raise ArgumentError, "unsupported df[] key: #{key.class}"
    end
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
  # Range / ArithmeticSequence / [start, count, step]), a boolean CArray
  # (SELECT), an integer CArray (GRID), or an Integer (a single row). Mask and
  # delete take any of them and are forwarded to the column indexer, so their
  # errors match the rest of CArray. Splice reuses the same classifier
  # (CArray.scan_index) but needs a contiguous slice, so it takes an Integer or
  # a step-1 BLOCK (Range, step-1 ArithmeticSequence, or [start, count]); a
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

  # df["name"] = ... : the column forms of []=.  Unlike the verbs, +[]=+ can
  # only ever mutate the receiver -- Ruby hands the right-hand side back as
  # the value of an assignment, so there is no way to return a new frame.
  # Membership is per-frame (§12-B), so a parent frame's column set is
  # untouched.
  #
  #   df["temp"] = col     -> bind the name to that column (a new name is added)
  #   df["temp"] = nil     -> remove the column
  #   df["temp"] = UNDEF   -> mask every cell of the column, in place
  private def column_assign(key, value)
    if value.nil?
      delete_column(key)
    elsif UNDEF.equal?(value)
      mask_column(key)
    elsif value.is_a?(CAFrame)
      raise ArgumentError,
            "df[name] = takes a column, not a CAFrame; escape one with " \
            "other[\"name\"], or splice rows with df[rows] = other"
    else
      rebind_column(key, value)
    end
  end

  # Bind +key+ to +column+, adding the name when it is new.  This is the one
  # place a column enters an existing frame, so it is where the axis-0 length
  # invariant is enforced (§12-A).  It is a replacement rather than an edit,
  # which is what sets it apart from the rest: +fill+ / +mask_eq+ /
  # +df[rows] = UNDEF+ write to the shared column and are therefore visible
  # wherever it is held, while this binds the name to a different column and
  # leaves the old one alone (the same rule +cast+ follows, for the physical
  # reason that a type change cannot reuse the buffer).
  private def rebind_column(key, column)
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
    raise KeyError, "no column #{key.inspect}" unless @columns.key?(key)
    @columns.delete(key)
    @nrow = 0 if @columns.empty? && @index.nil?
    self
  end

  # Mask every cell of a column, in place.  The row form (+df[rows] = UNDEF+)
  # masks the selected rows across every column; this is its column-wise
  # counterpart, and like it the write goes through to the stored column and
  # is visible through every alias.
  private def mask_column(key)
    col = @columns.fetch(key) { raise KeyError, "no column #{key.inspect}" }
    col[] = UNDEF
    self
  end

  # Column projection (memo §13.2): a view-frame holding the named columns as
  # aliases (zero-copy, sharing storage with the parent frame). Distinct from
  # +df[...]+, which escapes columns to raw CArrays, and from +filter+, which
  # selects rows. +select+ takes no block — row conditions go through +filter+
  # (old carray-dataframe fused the two into +select(cols) { cond }+; here they
  # are orthogonal and compose by chaining: +df.select(...).filter { ... }+).
  def select(*names)
    raise ArgumentError, "select requires at least one column name" if names.empty?
    cols = {}
    names.each do |name|
      key = name.to_s
      raise KeyError, "no column #{key.inspect}" unless @columns.key?(key)
      cols[key] = @columns[key]
    end
    rebuild(cols)
  end

  # Filter rows with a block that receives the frame and returns a boolean
  # column (memo §15). The block builds the mask from +f["col"]+ / +f.index+.
  # Keep the rows where the block's boolean selector is true.
  #
  # A masked (UNDEF) selector cell means the row's membership is *genuinely
  # undetermined* (e.g. the predicate read a masked input). By default such
  # rows are silently dropped, exactly as a false cell would be. Pass
  # +keep_masked: true+ to carry the UNDEF forward instead: the undetermined
  # rows survive into the result with their data cells masked (and their index
  # value kept, so the row stays identifiable), leaving a later, better-informed
  # pass to re-judge them. Definitely-true rows carry their values through
  # unchanged in both modes.
  def filter(keep_masked: false)
    mask = yield(self)
    unless mask.is_a?(CArray) && mask.data_type == :boolean
      raise ArgumentError,
            "filter block must return a boolean CArray (got #{mask.class})"
    end
    unless mask.shape[0] == @nrow
      raise ArgumentError,
            "filter mask has axis-0 length #{mask.shape[0]}, expected nrow #{@nrow}"
    end
    select_rows(mask, keep_masked: keep_masked)
  end

  # Move a column to the index and name the row axis after it (memo §3).
  # An index-role change: the data is unchanged, so this mutates self and
  # returns it (memo §3.8). Any existing index is replaced.
  def set_index(name)
    key = name.to_s
    raise KeyError, "no column #{key.inspect}" unless @columns.key?(key)
    idx = @columns[key]
    unless idx.ndim == 1
      raise ArgumentError, "index must be a 1-D column (got ndim #{idx.ndim})"
    end
    @columns.delete(key)
    @index     = idx
    @axis_name = key
    @nrow      = idx.shape[0]
    self
  end

  # Drop the index back into an ordinary column (the inverse of set_index).
  # Also an index-role change, so it mutates self (memo §3.8). The former
  # index becomes the first column, named after the row axis.
  def reset_index
    return self unless @index
    @columns   = { @axis_name => @index }.merge(@columns)
    @index     = nil
    @axis_name = DEFAULT_AXIS_NAME
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
  # orderable / object / datetime / categorical index works. The return type is
  # a row Hash and stays that way: zero matches raise KeyError, and duplicate
  # labels raise (go through +filter { |f| f.index.eq(label) }+ for the
  # multi-row, frame-returning path). Positional access is +df[i]+.
  def at(label)
    raise ArgumentError, "at requires an index (set one with set_index)" unless @index
    pos = @index.eq(label).where
    case pos.elements
    when 0
      raise KeyError, "no row with index label #{label.inspect}"
    when 1
      row(pos[0])
    else
      raise ArgumentError,
            "index label #{label.inspect} matches #{pos.elements} rows; " \
            "use filter { |f| f.index.eq(label) } for duplicate labels"
    end
  end

  # An independent frame — every column and the index materialized (§3.6).
  def copy
    cols = {}
    @columns.each { |k, v| cols[k] = v.copy }
    CAFrame.new(cols, axis_name: @axis_name, index: @index && @index.copy)
  end

  # +dup+ / +clone+ share the column data -- that is the CArray dup contract
  # (§3.6) -- but must not share the columns Hash itself: Ruby's shallow copy
  # hands over the same Hash object, so a membership edit (+append+ / +drop+ /
  # a +cast+ rebind) on the copy would show up in the original, which is the
  # one thing per-frame membership (§12-B) says never happens.
  private def initialize_copy(other)
    super
    @columns = @columns.dup
  end

  # --- metadata readers (memo §13.2) ------------------------------------
  # Each returns a fresh object; the live columns Hash is never exposed.

  # Variable (column) names in column order.  Returns +Array<String>+.
  def variable_names
    @columns.keys
  end

  # Variables (raw column CArrays) in column order.  Returns
  # +Array<CArray>+.  Equivalent to +df[*variable_names]+ but built
  # directly from the columns Hash.
  def variables
    @columns.values
  end

  # Number of variables (columns).
  def nvar
    @columns.size
  end

  # Number of rows (axis-0 length N).
  attr_reader :nrow

  # Row-axis name.
  attr_reader :axis_name

  # Index column (CArray) or nil.
  attr_reader :index

  # name => data_type, freshly derived.
  def data_types
    h = {}
    @columns.each { |k, v| h[k] = v.data_type }
    h
  end

  # @return [String]
  def inspect
    parts = @columns.map { |k, v| "#{k}:#{v.data_type}#{v.ndim > 1 ? v.shape[1..].inspect : ''}" }
    idx = @index ? " index=#{@axis_name.inspect}" : ""
    "#<CAFrame nrow=#{@nrow} vars=[#{parts.join(', ')}]#{idx}>"
  end

  private def rebuild(cols)
    CAFrame.new(cols, axis_name: @axis_name, index: @index)
  end

  private def coerce_column(col)
    if col.is_a?(CAFrame)
      raise ArgumentError,
            "a CAFrame cannot be a column (it answers to_ca as a 2-D matrix); " \
            "escape a column with df[\"name\"] or df.to_ca first"
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
    i += @nrow if i < 0
    unless i >= 0 && i < @nrow
      raise IndexError, "row index #{i} out of range (nrow=#{@nrow})"
    end
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
  # (any length). Columns are concatenated head + other + tail, so dtypes
  # promote and the row count shifts by other.nrow - span.
  private def splice_rows(selector, other)
    lo, hi = contiguous_span(selector)
    unless other.variable_names.sort == variable_names.sort
      raise ArgumentError,
            "splice frame has columns #{other.variable_names.inspect}, " \
            "expected the same set as #{variable_names.inspect}"
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
        else CArray.meld(pieces, axis: 0)         # CAMeld view; dtype mismatch
        end                                        # across pieces raises.
                                                   # For dtype conversion, cast
                                                   # the incoming +other+'s
                                                   # column beforehand — silent
                                                   # promotion in a splice would
                                                   # hide schema drift.
    end
    new_index = splice_index(other, lo, hi)
    @columns  = new_cols
    @index    = new_index
    @nrow     = @nrow - (hi - lo) + other.nrow
    self
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
    else CArray.meld(pieces, axis: 0)   # index dtype must match across frames
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

  private def select_rows(selector, keep_masked: false)
    if keep_masked && selector.is_a?(CArray) &&
       selector.data_type == :boolean && selector.has_mask?
      return select_rows_keep_masked(selector)
    end
    cols = {}
    @columns.each do |name, col|
      cols[name] = col[selector, *([nil] * (col.ndim - 1))]
    end
    new_index = @index ? @index[selector] : nil
    CAFrame.new(cols, axis_name: @axis_name, index: new_index)
  end

  private def select_rows_keep_masked(selector)
    keep       = selector.strip_mask(1)   # true where selected OR undetermined
    undet_kept = selector.is_masked[keep] # among kept rows, which were undetermined
    cols = {}
    @columns.each do |name, col|
      tail = [nil] * (col.ndim - 1)
      g = col[keep, *tail].copy
      g[undet_kept, *tail] = UNDEF
      cols[name] = g
    end
    new_index = @index ? @index[keep] : nil
    CAFrame.new(cols, axis_name: @axis_name, index: new_index)
  end

  private def positional_range?(range)
    (range.begin.nil? || range.begin.is_a?(Integer)) &&
      (range.end.nil? || range.end.is_a?(Integer))
  end
end

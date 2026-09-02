# ----------------------------------------------------------------------------
#
#  carray/categorical_iterator.rb
#
#  CACategoricalIterator — a per-category reduction dispatcher.  `cat` (a
#  CACategorical) brings the equivalence-class classification; `value` is the
#  payload.  `value.group_by_category(cat)` lays `value` out as a
#  category-contiguous eager copy by gathering it through `cat`'s cached
#  grouping plan (the counting sort lives on the categorical, built once and
#  shared across every payload column) and offers per-category reductions off
#  `cat.reduceat_index` as segment boundaries:
#
#      grp = value.group_by_category(cat)
#      grp.max      # per-category max
#      grp.median   # order statistics share the same surface
#      grp.stddev
#
#  This is the consumer of the sort_addr / reduceat_index foundation on
#  CACategorical.  Order statistics (median / percentile / quantile) cannot be
#  scattered — they need every value of a group held together — so the values
#  are materialized into contiguous blocks once, and every reduction (monoid or
#  order-stat) then folds those held blocks.
#
#  Each group is delegated to the same-named CArray reduction over that group's
#  members, so a group result equals `CArray#<reduction>` for those members and
#  the mask contract (empty / all-masked -> identity for sum/prod, UNDEF for
#  ratios) carries through unchanged.  Results are length-k CArrays aligned to
#  `cat.labels`; undefined slots are MASKED cells (never magic floats).  Output
#  data type and the empty / all-masked answer per method:
#
#      elements                     -> int64,      classified cells (incl. masked)
#      count / count_not_masked / count_masked / count(v) -> int64
#      sum                          -> value data type, empty/all-masked = 0 (identity)
#      prod                         -> float64,     empty/all-masked = 1 (identity)
#      max / min                    -> value data type, empty/all-masked = MASKED
#      mean                         -> float64,     empty/all-masked = MASKED
#      median / percentile          -> float64,     empty/all-masked = MASKED
#      variance / stddev (sample, ddof=1) -> float64, empty/all-masked = MASKED,
#                                                   single value = 0.0 (n=1 contract)
#      all / any                    -> boolean (boolean value data type only)
#      labels                       -> cat.labels
#
#  Generic iteration (the escape hatch for statistics not in the named surface),
#  matching each_slab / reduce_slab: each { |members| ... } yields per category,
#  reduce { |members| ... } / reduce(init) { |acc, e| ... } folds each category
#  to one value (length-k). map (an element-wise group-wise transform back to
#  the source shape) is a later pass -- use reduce for aggregation.
#
#  prod / all / any / count(v) are per-group fallbacks (they delegate to the
#  CArray reduction per category); a fused reduceat for them is a later pass.
#
#  Names (group_by_category / CACategoricalIterator) are provisional; the
#  contract (grouped copy + offsets + labels + per-category reduction) is the
#  ground truth.
#
#  The per-column gather and the segmented reduction both run in Ruby; the
#  counting sort itself (the dominant cost) is a C kernel cached on the
#  categorical, so a wide aggregate pays it once.
#
# ----------------------------------------------------------------------------

require "carray"

# A CAIterator over the categories of a CACategorical.  CAIterator is the
# family base (the built-in iterators like CAWindowIterator / CABlockIterator
# are defined in C); a Ruby `Foo < CAIterator` supplies its own behaviour and
# does not lean on the base machinery.  Like CASlabIterator, this class defines
# its own `each` (over the k categories, yielding each category's member slice),
# which drives the inherited Enumerable surface; the reduction methods (sum /
# mean / median / ...) aggregate the groups into length-k arrays.  The kernels
# are per-category slices of an eager, category-contiguous grouped copy.  This
# supersedes the older CAClassIterator.
class CACategoricalIterator < CAIterator

  # value : the payload CArray to reduce, one cell per categorical cell.
  # cat   : the CACategorical carrying the classification.
  #
  # Lays the value out category-contiguous by GATHERING it through the
  # categorical's cached grouping plan (the counting sort lives on `cat`, built
  # once and shared by every payload column and iterator — see
  # CACategorical's grouping-plan note). The plan gives the segment STARTS
  # (reduceat_index) and the group-major permutation (perm[slot] = source index
  # at that grouped slot, = the valid prefix of sort_addr); gathering value
  # through perm is the only per-column work. Excluded cells (masked or
  # out-of-vocabulary code) are absent from perm, so they never join a group;
  # the value mask rides the gather into the grouped copy.
  def initialize (value, cat)
    @cat       = cat
    @labels    = cat.labels
    @k         = cat.labels.size
    @value     = value                              # source, kept for #cumsum etc.
    @src_shape = value.shape                        # output shape for #map
    @ndim      = 1                                  # 1-D iterator over k categories
    @shape     = [@k]

    if value.elements == cat.elements
      # Flat classifier path (backward compat): cat classifies every cell of
      # value one-to-one, so eager counting-sort gather is meaningful.  This is
      # what all no-axis reductions consume — case C (all cells collapse into k
      # buckets) plus case B interpreted flatly.
      # category_sizes IS the per-group cell counts (what #elements returns);
      # the segment STARTS are its cached exclusive prefix scan (cat.reduceat_
      # index): offsets[c] = sum of counts[0...c]. Both come off the shared
      # plan, so the counting sort is not repeated here.
      @elements = cat.category_sizes.int64
      nvalid    = @elements.sum
      @offsets  = cat.reduceat_index                # cached segment STARTS (int64[k])
      # Group-major source indices = the valid prefix of the cached sort_addr.
      # With no classified cell the prefix is empty (and slicing a length-0
      # sort_addr would be out of range), so take the empty permutation directly.
      @perm     = nvalid > 0 ? cat.sort_addr[0...nvalid] : CArray.int64(0)
      @codes    = cat.codes.reshape(cat.elements)   # flat codes view (map re-walk / weights)
      # Gather value into category-contiguous order via the cached permutation
      # and materialise (the reduceat kernels read the grouped buffer's raw ptr,
      # so it must be a contiguous entity, not the selection view); the value
      # mask rides the gather. Payload-dependent, so this is the only part
      # rebuilt per column. With no classified cell (empty / all-excluded) there
      # is nothing to gather — an empty index into an empty source is out of
      # range — so build the empty grouped buffer directly.
      @grouped  = nvalid > 0 ? value.reshape(value.elements)[@perm].copy
                             : CArray.new(value.data_type, [0])
      @empty    = CArray.new(@grouped.data_type, [0])
    else
      # Shape mismatch: only per-fiber axis: dispatch could still work.  With a
      # 1-D value there is no fiber structure to broadcast into, so a mismatch
      # is unrecoverable (preserves the old strict check).  For higher-rank
      # value, defer validation to reduce time — check only that cat.ndim fits
      # one of the 3 axis: cases;
      # any no-axis reduce called on this iterator will surface the mismatch
      # because @grouped stays undefined.
      if value.ndim == 1 ||
         ! [1, value.ndim - 1, value.ndim].include?(cat.ndim)
        raise ArgumentError,
              "group_by_category: value.elements (#{value.elements}) != " \
              "cat.elements (#{cat.elements})" +
              (value.ndim == 1 ? "" :
                ". For per-fiber reduce use `.sum(axis: k)`; cat.ndim=" \
                "#{cat.ndim} must be 1 (case A), #{value.ndim} (case B), " \
                "or #{value.ndim - 1} (band-only) for h.ndim=#{value.ndim}.")
      end
    end
    self
  end

  # @overload each { |members| ... }
  #   Yields each category's members (a CArray slice of the grouped copy, in
  #   {#labels} order; an empty category yields an empty array).  Without a
  #   block, returns an Enumerator.  This is the own iteration that drives the
  #   inherited Enumerable methods (map / count / to_a / ...); it does not use
  #   the CAIterator base each / kernel_at_addr path.
  #   @yieldparam members [CArray]
  #   @return [Enumerator, self]
  def each
    return to_enum(:each) unless block_given?
    @k.times { |c| yield group_slice(c) }
    self
  end

  # @overload labels
  #   Returns the category vocabulary the results are aligned to.
  #   @return [Array]
  attr_reader :labels

  # @overload ngroups
  #   Returns the number of groups (= `labels.size`); the length of every
  #   per-group result CArray the reductions return.
  #   @return [Integer]
  def ngroups
    @k
  end

  # @overload elements
  #   Returns per-group cell counts (classified cells, including value-masked
  #   ones; = `cat.category_sizes`), a length-ngroups CArray aligned to
  #   {#labels}. The CAIterator count-family member — `CArray#elements`
  #   (structural, mask-independent) lifted per group.
  #   @return [CArray]
  def elements
    @elements
  end

  # Group-vocabulary alias for {#elements}; reads naturally next to
  # {#ngroups} and mirrors `CACategorical#category_sizes`.
  alias group_sizes elements

  # @overload inspect
  #   Returns a compact one-line summary — the group count, the label
  #   vocabulary, and the per-group cell counts — instead of dumping the
  #   internal grouped/value/codes buffers.
  #   @return [String]
  def inspect
    "#<#{self.class} ngroups=#{@k} labels=#{@labels.inspect} " \
    "elements=#{@elements.to_a.inspect}>"
  end

  # @overload count_not_masked
  #   Returns the per-category count of present (non-masked) values as int64
  #   — the denominator the value reductions actually divide by.  Equals
  #   {#elements} unless the value carries a mask.  A count is always defined,
  #   so an empty category is `0` (never masked).
  #   @return [CArray]
  # @overload count_not_masked(axis:)
  #   Per-fiber per-category count of present (non-masked) values along `axis`
  #   (int64, shape [K, ...band]).  Empty cells are `0`.
  #   @param axis [Integer]
  #   @return [CArray]
  def count_not_masked(axis: nil)
    return axis_moments(axis)[:count] if axis
    m = moments
    m ? m[:count] : per_category(CA_INT64) { |s| s.count_not_masked }
  end

  # @overload count(v = <none>)
  #   Per-category count, mirroring `CArray#count` per group. No argument
  #   returns {#count_not_masked} (present cells); `count(UNDEF)` returns
  #   {#count_masked}; `count(v)` counts cells whose value equals `v`.
  #   @return [CArray] length-k int64, aligned to {#labels}
  # @overload count(axis:)
  #   No-arg + axis: = per-fiber per-category count_not_masked (shape [K, ...band]).
  #   `count(v, axis:)` (value equality) and `count(UNDEF, axis:)` are not
  #   implemented; use them without `axis:`.
  #   @param axis [Integer]
  #   @return [CArray]
  def count (*args, axis: nil)
    if axis
      return count_not_masked(axis: axis) if args.empty?
      raise NotImplementedError,
            "CACategoricalIterator#count(v, axis:) is not implemented — " \
            "value-equality count is available without axis:."
    end
    return count_not_masked if args.empty?
    # Delegate per group to CArray#count (handles count(UNDEF) -> masked count and
    # count(v) alike, with core's exact data type equality). The group slice is a
    # CABlock, whose own #count is the block geometry accessor, so dispatch
    # CArray#count explicitly. (Not fused: a value-equality reduceat would have
    # to reproduce core's cross-type / out-of-range equality exactly.)
    cnt = CArray.instance_method(:count)
    per_category(CA_INT64) { |s| cnt.bind_call(s, *args) }
  end

  # @overload count_masked
  #   Returns the per-category count of masked (missing) values as int64.
  #   Empty categories are `0`.
  #   @return [CArray]
  # @overload count_masked(axis:)
  #   Not implemented; call it without `axis:`.
  #   @param axis [Integer]
  #   @return [CArray]
  def count_masked(axis: nil)
    if axis
      raise NotImplementedError,
            "CACategoricalIterator#count_masked(axis:) is not implemented — " \
            "call it without axis:."
    end
    m = moments
    m ? @elements - m[:count] : per_category(CA_INT64) { |s| s.count_masked }
  end

  # @overload sum
  #   Returns per-category sums in the value data type.  An empty or fully-masked
  #   category sums the empty set, which is the additive identity `0`
  #   (unmasked) — the same contract as `CArray#sum` on an empty / all-masked
  #   array.
  #   @return [CArray]
  # @overload sum(axis:)
  #   Returns per-category sums per fiber along `axis`.  Cat may be 1-D (case
  #   A, broadcasts across band axes), same rank as source (case B, per-fiber
  #   independent classifier), or one rank less (band-only, constant along
  #   reduce axis).  Output shape = `[K, ...source.shape without axis]`.
  #   @param axis [Integer] reduce axis of the source value.
  #   @return [CArray]
  def sum(axis: nil)
    return axis_sum(axis) if axis
    m = moments
    return per_category(@grouped.data_type) { |s| s.sum } unless m
    out = CArray.new(@grouped.data_type, [@k])
    out[] = m[:sum]                 # cast float64 sums -> value data type (empty -> 0)
    out
  end

  # @overload accumulate
  #   Returns per-category sums folded in the value's own data type, wrapping at
  #   its width, as the core `accumulate` does.  This is the exact in-type fold:
  #   `sum` reads its answer off a float64 moment and casts back, so it loses
  #   the low bits of a wide integer payload and does not wrap.  An empty or
  #   fully-masked category accumulates the empty set, the additive identity `0`
  #   (unmasked).
  #   @return [CArray]
  # @overload accumulate(axis:)
  #   Per-fiber per-category in-type sums along `axis`.  Output shape =
  #   `[K, ...source.shape without axis]`.
  #   @param axis [Integer] reduce axis of the source value.
  #   @return [CArray]
  def accumulate(axis: nil)
    return axis_by_masked_copy(axis, :accumulate, @value.data_type) if axis
    per_category(@grouped.data_type) { |s| s.accumulate }
  end

  # @overload max
  #   Returns per-category maxima in the value data type.  Empty categories are
  #   MASKED.
  #   @return [CArray]
  # @overload max(axis:)
  #   Per-fiber per-category maxima along `axis` (h's data type, masked where empty).
  #   @param axis [Integer]
  #   @return [CArray]
  def max(axis: nil)
    return axis_moments(axis)[:max] if axis
    m = moments
    m ? m[:max] : per_category(@grouped.data_type) { |s| s.max }
  end

  # @overload min
  #   Returns per-category minima in the value data type.  Empty categories are
  #   MASKED.
  #   @return [CArray]
  # @overload min(axis:)
  #   Per-fiber per-category minima along `axis` (h's data type, masked where empty).
  #   @param axis [Integer]
  #   @return [CArray]
  def min(axis: nil)
    return axis_moments(axis)[:min] if axis
    m = moments
    m ? m[:min] : per_category(@grouped.data_type) { |s| s.min }
  end

  # @overload mean
  #   Returns per-category means as float64.  Empty categories are MASKED.
  #   @return [CArray]
  # @overload mean(axis:)
  #   Per-fiber per-category means (float64, empty group cells MASKED).
  #   @param axis [Integer]
  #   @return [CArray]
  def mean(axis: nil)
    return axis_mean(axis) if axis
    m = moments
    return per_category(CA_FLOAT64) { |s| s.mean } unless m
    cnt = m[:count]
    out = m[:sum] / cnt.float64      # count 0 -> NaN, masked next
    out[cnt.eq(0)] = UNDEF           # empty / all-masked category -> MASKED
    out
  end

  # @overload median
  #   Returns per-category medians as float64.  Empty categories are MASKED.
  #   @return [CArray]
  def median(axis: nil)
    axis_order_stat_defer!(:median) if axis
    percentile(50.0)
  end

  # @overload percentile(p)
  #   Returns the per-category `p`-th percentile as float64 (`p` in 0..100,
  #   `:linear` interpolation, matching `CArray#percentile`).  Empty categories
  #   are MASKED.  Order statistics need every value of a group held together —
  #   this is the reduceat that only the eager grouped copy can serve.
  #   @param p [Numeric] percentile in 0..100.
  #   @return [CArray]
  def percentile (p, axis: nil)
    axis_order_stat_defer!(:percentile) if axis
    unless MONOID_TYPES.include?(@grouped.data_type)
      return per_category(CA_FLOAT64) { |s| s.percentile(p) }
    end
    out = CArray.float64(@k)
    @grouped.send(:__reduceat_percentile__, @offsets, p.to_f, out)
    out
  end

  # @overload quantile
  #   Returns the per-category five-number summary `[min, Q1, median, Q3, max]`
  #   as five length-k float64 CArrays (matching `CArray#quantile`): the
  #   percentiles at 0 / 25 / 50 / 75 / 100. Empty / all-masked categories are
  #   MASKED. For a single fraction q in 0..1 use `percentile(q * 100)`.
  #   @return [Array<CArray>]
  def quantile
    unless MONOID_TYPES.include?(@grouped.data_type)
      return [0, 25, 50, 75, 100].map { |p| percentile(p) }
    end
    outs = Array.new(5) { CArray.float64(@k) }
    @grouped.send(:__reduceat_quantile__, @offsets, *outs)
    outs
  end

  # @overload variance
  #   Returns per-category SAMPLE variance (ddof=1) as float64.  Matches
  #   `CArray#variance` per group: an empty or fully-masked category is MASKED,
  #   a single-value category is `0.0` (CArray's n=1 contract), n>=2 is the
  #   sample variance.
  #   @return [CArray]
  def variance(axis: nil)
    return axis_by_masked_copy(axis, :variance) if axis
    m = moments
    return per_category(CA_FLOAT64) { |s| s.variance } unless m
    cnt   = m[:count]
    means = m[:sum] / cnt.float64    # per-segment mean (garbage where count 0/1,
    out   = CArray.float64(@k)       #   ignored by the kernel's n<2 guards)
    @grouped.send(:__reduceat_variance__, @offsets, means, cnt, out)
    out
  end

  # @overload stddev
  #   Returns per-category SAMPLE standard deviation (ddof=1) as float64.
  #   Matches `CArray#stddev` per group (empty / all-masked MASKED,
  #   single-value `0.0`).
  #   @return [CArray]
  def stddev(axis: nil)
    return axis_by_masked_copy(axis, :stddev) if axis
    m = moments
    return per_category(CA_FLOAT64) { |s| s.stddev } unless m
    variance.sqrt                    # sqrt propagates the n=0 mask
  end

  # @overload prod
  #   Returns per-category products as float64 (matching `CArray#prod`). An
  #   empty / fully-masked category is `1.0` (the multiplicative identity).
  #   Single-pass reduceat for numeric values; per-group fallback otherwise.
  #   @return [CArray]
  # @overload prod(axis:)
  #   Per-fiber per-category products (float64, shape [K, ...band]).  Empty
  #   group cells `1.0` (identity).
  #   @param axis [Integer]
  #   @return [CArray]
  def prod(axis: nil)
    return axis_prod(axis) if axis
    return per_category(CA_FLOAT64) { |s| s.prod } unless MONOID_TYPES.include?(@grouped.data_type)
    out = CArray.float64(@k)
    @grouped.send(:__reduceat_prod__, @offsets, out)
    out
  end

  # @overload all
  #   Returns the per-category `all` as boolean (matching `CArray#all`): true
  #   iff every present value is truthy (empty category -> true, vacuously).
  #   The value data type must be boolean, as for `CArray#all`.
  #   @return [CArray]
  def all
    aa = all_any
    aa ? aa[:all] : per_category(CA_BOOLEAN) { |s| s.all }
  end

  # @overload any
  #   Returns the per-category `any` as boolean (matching `CArray#any`): true
  #   iff some present value is truthy (empty category -> false). The value
  #   data type must be boolean, as for `CArray#any`.
  #   @return [CArray]
  def any
    aa = all_any
    aa ? aa[:any] : per_category(CA_BOOLEAN) { |s| s.any }
  end

  # ---- tier 2 (fused / population / position) ------------------------------

  # @overload minmax
  #   Returns the per-category `[min, max]` pair (each a length-k CArray in the
  #   value data type; empty categories MASKED), matching `CArray#minmax`. Both come
  #   from the single cached moments pass.
  #   @return [Array<CArray>]
  # @overload minmax(axis:)
  #   Per-fiber `[min_ca, max_ca]` along `axis` (each shape [K, ...band], h's data type,
  #   empty group cells MASKED).  Ruby Array of two CArrays, not stacked.
  #   @param axis [Integer]
  #   @return [Array<CArray>]
  def minmax(axis: nil)
    return [min(axis: axis), max(axis: axis)] if axis
    [min, max]
  end

  # @overload variancep
  #   Per-category POPULATION variance (ddof=0) as float64, matching
  #   `CArray#variancep`: empty / all-masked -> MASKED, single value -> 0.0.
  #   Derived from the sample variance (variancep = variance * (n-1) / n), so it
  #   reuses the centred two-pass kernel with no extra walk.
  #   @return [CArray]
  def variancep(axis: nil)
    return axis_by_masked_copy(axis, :variancep) if axis
    m = moments
    return per_category(CA_FLOAT64) { |s| s.variancep } unless m
    cnt = m[:count]
    vp  = variance * (cnt - 1).float64 / cnt.float64
    vp[cnt.eq(0)] = UNDEF                 # empty / all-masked stays masked
    vp
  end

  # @overload stddevp
  #   Per-category POPULATION standard deviation (ddof=0) as float64.
  #   @return [CArray]
  # @overload stddevp(axis:)
  #   Per-fiber per-category population stddev (float64, empty group cells MASKED).
  #   @param axis [Integer]
  #   @return [CArray]
  def stddevp(axis: nil)
    return axis_by_masked_copy(axis, :stddevp) if axis
    m = moments
    return per_category(CA_FLOAT64) { |s| s.stddevp } unless m
    variancep.sqrt
  end

  # @overload min_index
  #   Per-category group-local index of the minimum — the position within the
  #   category's members (source order) — matching `CArray#min_index` per group.
  #   Empty / all-masked categories are MASKED. Single-pass fused reduceat for
  #   numeric values; per-group fallback otherwise.
  #   @return [CArray] length-k int64
  def min_index
    am = arg_minmax
    am ? am[:min] : per_category(CA_INT64) { |s| s.min_index }
  end

  # @overload max_index
  #   Per-category group-local index of the maximum. See {#min_index}.
  #   @return [CArray] length-k int64
  def max_index
    am = arg_minmax
    am ? am[:max] : per_category(CA_INT64) { |s| s.max_index }
  end

  # @overload min_addr
  #   Per-category flat source address of the minimum — which cell of the source
  #   value holds it, matching `CArray#min_addr` per group. Unlike {#min_index}
  #   (the group-local rank) this indexes back into the original array
  #   (`value.reshape(value.elements)[grp.min_addr]`). Empty categories MASKED.
  #   @return [CArray] length-k int64
  def min_addr
    group_addr(min_index)
  end

  # @overload max_addr
  #   Per-category flat source address of the maximum. See {#min_addr}.
  #   @return [CArray] length-k int64
  def max_addr
    group_addr(max_index)
  end

  # @overload sort_addr
  #   Per-category sort by flat source address. Returns a length-nvalid
  #   (= `elements.sum`) int64 CArray of the flat SOURCE addresses that sort each
  #   category's members, in group-major order: segment `c` holds category `c`'s
  #   source addresses in ascending-value order, segments concatenated in
  #   {#labels} order. So `value.reshape(value.elements)[grp.sort_addr]` yields
  #   the values grouped and sorted within each group, and splitting by the
  #   {#elements} prefix sum gives per-group. Excluded cells (in no category) are
  #   omitted. A masked value sorts to the tail of its segment (as `CArray#sort`
  #   sends masked cells to the end), so with a mask the first address is the
  #   minimum but the last is the masked cell, not the maximum.
  #
  #   Unlike {#min_index} / {#max_index} (group-local rank), this indexes back
  #   into the original array. There is no group-local sort surface: a
  #   group-local rank order is weak (the grouped copy is already
  #   category-contiguous), so only the source-address form is offered, mirroring
  #   {#min_addr} vs the skipped group-local min_index-into-source.
  #   @return [CArray] length-nvalid int64
  def sort_addr
    out = CArray.int64(@grouped.elements)
    @k.times do |c|
      lo = @offsets[c]
      hi = (c + 1 < @k) ? @offsets[c + 1] : @grouped.elements
      next unless hi > lo
      # View-local sort order of the segment (0..size-1), lifted to grouped
      # slots, then mapped back to source addresses via perm.
      out[lo...hi] = perm[@grouped[lo...hi].sort_addr + lo]
    end
    out
  end

  # @overload wsum(weights)
  #   Per-category weighted sum as float64, matching `CArray#wsum`. `weights` is
  #   a per-cell weight CArray in the source order (same elements as the value).
  #   Empty / all-masked category -> 0.0 (the additive identity). A cell is
  #   skipped iff its value OR its weight is masked (core's contract).
  #   @param weights [CArray]
  #   @return [CArray]
  # @overload wsum(weights, axis:)
  #   Per-fiber per-category weighted sum along `axis`.  `weights` must have
  #   shape == source.shape (rev3 requires explicit broadcast; wrap 1-D or
  #   band-shape weights via `.broadcast_to(*source.shape)` at the call site).
  #   Empty group cell → `0.0` (identity).  Mask contract: cell contributes iff
  #   value AND weight are present.
  #   @param weights [CArray]
  #   @param axis [Integer]
  #   @return [CArray]
  def wsum (weights, axis: nil)
    return axis_wsum_wmean(weights, axis)[0] if axis
    wg = scatter_weights(weights)
    return kernel_weighted(wg)[0] if MONOID_TYPES.include?(@grouped.data_type)
    fold_weighted(wg, 0.0) { |v, ws| v.wsum(ws) }
  end

  # @overload wmean(weights)
  #   Per-category weighted mean as float64, matching `CArray#wmean`. Empty
  #   category -> MASKED; a present category whose weights sum to zero -> NaN
  #   (core's 0/0 contract).
  #   @param weights [CArray]
  #   @return [CArray]
  # @overload wmean(weights, axis:)
  #   Per-fiber per-category weighted mean along `axis`.  Same weights-shape
  #   contract as {#wsum} (weights.shape == source.shape).  Empty cell → MASKED;
  #   a present cell whose weights sum to zero → NaN (0/0 core contract).
  #   @param weights [CArray]
  #   @param axis [Integer]
  #   @return [CArray]
  def wmean (weights, axis: nil)
    return axis_wsum_wmean(weights, axis)[1] if axis
    wg = scatter_weights(weights)
    return kernel_weighted(wg)[1] if MONOID_TYPES.include?(@grouped.data_type)
    fold_weighted(wg, UNDEF) { |v, ws| v.wmean(ws) }
  end

  # @overload reduce { |members| ... }
  #   Custom per-category reduction (the escape hatch for statistics not in the
  #   named surface), mirroring `CArray#reduce_slab`. The block receives each
  #   category's members (a CArray) and returns one value per category.
  #   @yieldparam members [CArray]
  #   @return [CArray] length-k, aligned to {#labels}
  # @overload reduce(init) { |acc, elem| ... }
  #   Per-category fiber fold: each category's members are folded element by
  #   element starting from `init`.
  #   @param init [Object] initial accumulator.
  #   @return [CArray] length-k
  def reduce (*args, data_type: nil, &blk)
    raise LocalJumpError, "no block given (yield)" unless blk
    dt = data_type || CA_OBJECT
    if args.empty?
      per_category(dt) { |s| blk.call(s) }
    else
      init = args[0]
      per_category(dt) { |s|
        acc = init
        s.each { |e| acc = blk.call(acc, e) }
        acc
      }
    end
  end

  # @overload map(data_type: nil) { |members| ... }
  #   Group-wise element-wise transform, mirroring `CArray#map_slab`. The block
  #   receives each category's members and returns either a same-length CArray
  #   (scattered back cell for cell) or a scalar (broadcast over the group's
  #   cells). Returns a NEW CArray shaped like the source `value`; the original
  #   is not modified (`value[] = grp.map { ... }` for in-place). Excluded cells
  #   (in no category) are UNDEF in the result.
  #   @yieldparam members [CArray]
  #   @return [CArray] shaped like the source value
  def map (data_type: nil)
    raise LocalJumpError, "no block given (yield)" unless block_given?
    dt = data_type || @grouped.data_type
    # Apply the block per category, assembled in grouped (category-contiguous)
    # order: a same-length result scatters cell for cell, a scalar broadcasts.
    transformed = CArray.new(dt, [@grouped.elements])
    @k.times do |c|
      lo = @offsets[c]
      hi = (c + 1 < @k) ? @offsets[c + 1] : @grouped.elements
      transformed[lo...hi] = yield(@grouped[lo...hi]) if hi > lo
    end
    # Scatter back to source positions via the permutation (grouped-order source
    # indices). Excluded cells are absent from perm and stay UNDEF.
    out = CArray.new(dt, @src_shape)
    out[] = UNDEF
    out.reshape(@codes.elements)[perm] = transformed
    out
  end

  # ---- segment scan: within-category running statistics ------------------
  #
  # The per-element-emit siblings of the reductions: unlike a reduction (which
  # collapses each category to one value) a scan preserves the source shape,
  # each cell holding its category's running statistic up to and including that
  # cell, in source (row-major) order.  A category is a partition (each cell is
  # in exactly one category), so the running value is single-valued.  The flat
  # categorical grouping is the one-band case of the axis-group scan, so each
  # routes straight through the fused C kernel __axis_group_scan__ (the same one
  # CAGroupIterator drives) with the whole source as a single grouped axis and
  # the categorical's codes as the single bundle -- which yields SOURCE-ORDER
  # output directly, so no counting-sort inverse permutation is needed.
  # Excluded (out-of-vocabulary / masked-code) and source-masked cells join no
  # running total and are UNDEF.  Mirroring the reductions (sum / mean), a scan
  # takes no axis argument.  cumsum / cumprod -> float64, cummax / cummin
  # preserve the value data type, cumcount -> int64 (1-based within-category
  # ordinal); an object value data type is carried by the kernel's object branch.

  # @overload cumsum
  #   Per-category inclusive running sum (float64), source-shaped.
  #   @return [CArray]
  # @overload cumprod
  #   Per-category inclusive running product (float64), source-shaped.
  #   @return [CArray]
  # @overload cummax
  #   Per-category inclusive running maximum (value data type), source-shaped.
  #   @return [CArray]
  # @overload cummin
  #   Per-category inclusive running minimum (value data type), source-shaped.
  #   @return [CArray]
  # @overload cumcount
  #   Per-category 1-based within-category ordinal (int64), source-shaped.
  #   @return [CArray]
  [:cumsum, :cumprod, :cummax, :cummin, :cumcount].each do |op|
    define_method(op) { scan(op) }
  end

  private

  # Axis-aware moments (count / sum / min / max) — computed once per axis via
  # the fused per-fiber scatter-reduce C kernel and cached (matches the flat
  # #moments caching in spirit: pay one kernel per {iterator, axis} pair, share
  # across sum / mean / min / max / minmax / count* consumers).  Returns
  # `{count: <int64>, sum: <float64>, min: <h's type, masked>, max: <h's type, masked>}`,
  # all shape [K, ...band].
  def axis_moments (axis)
    @axis_moments_cache ||= {}
    cached = @axis_moments_cache[axis]
    return cached if cached
    h = @value
    unless axis.is_a?(Integer) && axis >= 0 && axis < h.ndim
      raise ArgumentError,
            "group_by_category.<reduce>(axis: #{axis.inspect}): axis must be an " \
            "Integer in [0, #{h.ndim}) for source h with shape #{h.shape}"
    end
    codes_h_shape = resolve_axis_codes(@cat.codes, h.shape, axis)
    band          = h.shape.dup; band.delete_at(axis)
    out_shape     = [@k] + band
    counts        = CArray.int64(*out_shape)
    sums          = CArray.float64(*out_shape)
    mins          = CArray.new(h.data_type, out_shape)
    maxs          = CArray.new(h.data_type, out_shape)
    h.__send__(:__fiber_scatter_moments__, codes_h_shape, axis, @k,
               counts, sums, mins, maxs)
    @axis_moments_cache[axis] = {count: counts, sum: sums, min: mins, max: maxs}
  end

  # Axis-aware sum: from moments, cast float64 sums to h's data type so empty-group
  # identity 0 rides (matching flat #sum).
  def axis_sum (axis)
    m   = axis_moments(axis)
    out = CArray.new(@value.data_type, m[:sum].shape)
    out[] = m[:sum]
    out
  end

  # Axis-aware mean: sums / counts (float64); empty group cells (count=0) MASKED.
  # Matches flat #mean per fiber.
  def axis_mean (axis)
    m   = axis_moments(axis)
    cnt = m[:count]
    out = m[:sum] / cnt.float64      # count 0 -> NaN
    out[cnt.eq(0)] = UNDEF           # empty / all-masked -> MASKED
    out
  end

  # Axis-aware reduction by masked copy — Ruby-level per-c mask, then delegate
  # to the source's own axis-aware kernel, so the core contract for `op` rides
  # unchanged.  Used by the variance family (a centred two-pass numeric
  # aggregate, hitting the same ε-close kernel per (group, axis) that
  # CArray#variance uses) and by `accumulate` (whose in-type wrapping fold has
  # no float64 moment to read it off).  Order (median / percentile / quantile)
  # is genuinely order-statistical (needs a sort per group) and remains
  # deferred.
  #
  # Cost: K axis-reductions over an h-shaped local (most cells masked away for
  # each c) — bounded by K, typically small.  A fused per-fiber variance
  # kernel is a natural follow-on if bench demands it.
  def axis_by_masked_copy (axis, op, out_data_type = CA_FLOAT64)
    h = @value
    unless axis.is_a?(Integer) && axis >= 0 && axis < h.ndim
      raise ArgumentError,
            "group_by_category.#{op}(axis: #{axis.inspect}): axis must be an " \
            "Integer in [0, #{h.ndim}) for source h with shape #{h.shape}"
    end
    full_c    = resolve_axis_codes(@cat.codes, h.shape, axis)
    band      = h.shape.dup; band.delete_at(axis)
    out       = CArray.new(out_data_type, [@k] + band)
    slot_idx  = [nil] + [nil] * band.size    # placeholder; c fills slot 0
    codes_bad = full_c.has_mask? ? full_c.is_masked : nil
    @k.times do |c|
      h_local = h.copy
      # Boolean of cells that DO belong to group c (with codes present).  On
      # any masked codes cell the codes.eq(c) result carries UNDEF, which
      # naturally reads as "not in group c" for our exclusion purpose.
      in_c = full_c.eq(c)
      exclude = in_c.not
      exclude = exclude | codes_bad if codes_bad
      h_local[exclude] = UNDEF
      slice = h_local.__send__(op, axis: axis)   # float64, band shape, mask carries n<contract
      slot_idx[0] = c
      out[*slot_idx] = slice
    end
    out
  end

  # Axis-aware wsum + wmean fused (single kernel call, both outputs).  Returns
  # [wsum_ca, wmean_ca].  Weights must match source shape exactly (explicit
  # broadcast on the call site for 1-D or band-shape weights).  A cell
  # contributes iff its value AND its weight are present.
  def axis_wsum_wmean (weights, axis)
    h = @value
    unless axis.is_a?(Integer) && axis >= 0 && axis < h.ndim
      raise ArgumentError,
            "group_by_category.wsum/wmean(axis: #{axis.inspect}): axis must " \
            "be an Integer in [0, #{h.ndim}) for source h with shape #{h.shape}"
    end
    unless weights.is_a?(CArray) && weights.shape == h.shape
      raise ArgumentError,
            "group_by_category.wsum/wmean(axis: #{axis}): weights.shape " \
            "#{weights.respond_to?(:shape) ? weights.shape.inspect : weights.class} " \
            "must equal source.shape #{h.shape.inspect}. Wrap 1-D / band-shape " \
            "weights via `.broadcast_to(*source.shape)` before passing."
    end
    codes_h_shape = resolve_axis_codes(@cat.codes, h.shape, axis)
    weights_f64   = weights.data_type == CA_FLOAT64 ? weights : weights.float64
    band          = h.shape.dup; band.delete_at(axis)
    ws_out        = CArray.float64(*([@k] + band))
    wm_out        = CArray.float64(*([@k] + band))
    h.__send__(:__fiber_scatter_wsum_wmean__, codes_h_shape, weights_f64,
               axis, @k, ws_out, wm_out)
    [ws_out, wm_out]
  end

  # Axis-aware prod: dedicated kernel (identity 1.0, separate from moments to
  # avoid conflating with sum's zero-identity memset).
  def axis_prod (axis)
    h = @value
    unless axis.is_a?(Integer) && axis >= 0 && axis < h.ndim
      raise ArgumentError,
            "group_by_category.prod(axis: #{axis.inspect}): axis must be an " \
            "Integer in [0, #{h.ndim}) for source h with shape #{h.shape}"
    end
    codes_h_shape = resolve_axis_codes(@cat.codes, h.shape, axis)
    band          = h.shape.dup; band.delete_at(axis)
    out           = CArray.float64(*([@k] + band))
    h.__send__(:__fiber_scatter_prod__, codes_h_shape, axis, @k, out)
    out
  end

  # Broadcast `codes` to `h_shape` per PROPOSAL §2.2 3-case positional rule.
  # Returns a broadcast view of codes at h_shape (or codes itself for case B).
  # Raises ArgumentError with a message that enumerates all 3 accepted shapes.
  def resolve_axis_codes (codes, h_shape, axis)
    ndim = h_shape.size
    band = h_shape.dup; band.delete_at(axis)
    case codes.ndim
    when 1
      unless codes.shape == [h_shape[axis]]
        axis_shape_mismatch!(codes.shape, h_shape, axis, band)
      end
      view_shape = Array.new(ndim, 1); view_shape[axis] = h_shape[axis]
      codes.reshape(*view_shape).broadcast_to(*h_shape)
    when ndim
      unless codes.shape == h_shape
        axis_shape_mismatch!(codes.shape, h_shape, axis, band)
      end
      codes
    when ndim - 1
      unless codes.shape == band
        axis_shape_mismatch!(codes.shape, h_shape, axis, band)
      end
      view_shape = h_shape.dup; view_shape[axis] = 1
      codes.reshape(*view_shape).broadcast_to(*h_shape)
    else
      axis_shape_mismatch!(codes.shape, h_shape, axis, band)
    end
  end

  def axis_shape_mismatch! (cat_shape, h_shape, axis, band)
    raise ArgumentError,
          "group_by_category.sum(axis: #{axis}): cat.shape=#{cat_shape.inspect} " \
          "does not fit any of the 3 accepted forms for h.shape=#{h_shape.inspect}: " \
          "case A cat.shape=[#{h_shape[axis]}], " \
          "case B cat.shape=#{h_shape.inspect}, " \
          "band-only cat.shape=#{band.inspect}."
  end

  # Order-stat axis: is deferred to Phase 4 (per-fiber counting-sort C kernel).
  # Called from median / percentile / variance / stddev when axis: is given.
  def axis_order_stat_defer! (op)
    raise NotImplementedError,
          "CACategoricalIterator##{op}(axis:) is not implemented — order " \
          "statistics are available without axis:."
  end

  # Drive a segment scan through the axis-group scan kernel: the whole value as
  # one grouped axis, the flat codes as the single bundle.  The kernel emits in
  # source order, so the flat result reshapes straight back to the source shape.
  def scan (op)
    @value.reshape(@value.elements)
          .__axis_group_scan__([0], [[@codes, @k, [0]]], op)
          .reshape(*@src_shape)
  end


  # Permutation: perm[slot] = the source index whose value sits at that grouped
  # slot. This is the valid prefix of the categorical's cached sort_addr, sliced
  # at construction (the same counting sort that lays out @grouped), so #map /
  # #sort_addr / the *_addr reductions read it for free.
  def perm
    @perm
  end

  # Lay a per-cell weight array out in category-contiguous order (same layout as
  # @grouped), so wsum / wmean can pair each group's values with its weights.
  # Weights are coerced to float64; the same counting-sort scatter propagates
  # the weight mask and skips excluded cells, so wg lines up with @grouped.
  def scatter_weights (weights)
    unless weights.elements == @codes.elements
      raise ArgumentError,
            "wsum/wmean: weights.elements (#{weights.elements}) != " \
            "value.elements (#{@codes.elements})"
    end
    wf = weights.float64
    wg = CArray.float64(@grouped.elements)
    @codes.send(:__categorical_scatter__, wf.reshape(wf.elements),
                @offsets.copy, wg, @k)
    wg
  end

  # Map a per-category group-local index to the flat source address via the
  # permutation (grouped slot -> source index). The min/max sits at grouped slot
  # offsets[c] + local_index[c]; perm carries it back to the source. Empty
  # categories (masked local index) stay masked.
  def group_addr (local_index)
    out = CArray.int64(@k)
    @k.times do |c|
      out[c] = local_index.is_masked[c] ? UNDEF
                                        : perm[@offsets[c] + local_index[c]]
    end
    out
  end

  # Fused per-segment weighted sum + weighted mean (one C pass over the grouped
  # copy, weights in group order). Returns [wsum, wmean]; wmean is masked where a
  # segment has no present (value AND weight) pair. Numeric value data types only.
  def kernel_weighted (wg)
    ws = CArray.float64(@k)
    wm = CArray.float64(@k)
    @grouped.send(:__reduceat_wsum_wmean__, @offsets, wg, ws, wm)
    [ws, wm]
  end

  # Per-group weighted fallback for non-numeric value data types (complex): delegate
  # each group to CArray#wsum / #wmean. Empty segments take the given identity.
  def fold_weighted (wg, empty)
    out = CArray.float64(@k)
    @k.times do |c|
      lo = @offsets[c]
      hi = (c + 1 < @k) ? @offsets[c + 1] : @grouped.elements
      out[c] = hi > lo ? yield(@grouped[lo...hi], wg[lo...hi]) : empty
    end
    out
  end

  # The members of category `c` as a CArray slice of the grouped copy.  An empty
  # category (zero-width segment) yields the shared empty array — a zero-length
  # slice cannot be taken directly, and an empty array carries the same reduction
  # contract we want (identity for sum, UNDEF for ratios).
  def group_slice (c)
    lo = @offsets[c]
    hi = (c + 1 < @k) ? @offsets[c + 1] : @grouped.elements
    hi > lo ? @grouped[lo...hi] : @empty
  end

  # Single-pass reduceat moments (count / sum / min / max per category), computed
  # once over the grouped copy and cached — the whole point of the eager copy is
  # that one scatter is followed by cheap single-pass reductions with no
  # per-segment views.  Nil for a non-numeric value data type (complex / object /
  # bool), where the monoid reductions fall back to per_category.
  # numeric value data types the C moments kernel handles (int8..float64); bool /
  # complex / object fall back to per_category.
  MONOID_TYPES = %i[int8 uint8 int16 uint16 int32 uint32
                    int64 uint64 float32 float64].freeze

  def moments
    return @moments if defined?(@moments)
    @moments =
      if MONOID_TYPES.include?(@grouped.data_type)
        dt     = @grouped.data_type
        counts = CArray.int64(@k)
        sums   = CArray.float64(@k)
        mins   = CArray.new(dt, [@k])
        maxs   = CArray.new(dt, [@k])
        @grouped.send(:__reduceat_moments__, @offsets, counts, sums, mins, maxs)
        { count: counts, sum: sums, min: mins, max: maxs }
      end
  end

  # Single-pass fused group-local argmin / argmax (min_index / max_index),
  # cached. Nil for a non-numeric value data type (fall back to per_category).
  def arg_minmax
    return @arg_minmax if defined?(@arg_minmax)
    @arg_minmax =
      if MONOID_TYPES.include?(@grouped.data_type)
        mn = CArray.int64(@k)
        mx = CArray.int64(@k)
        @grouped.send(:__reduceat_argminmax__, @offsets, mn, mx)
        { min: mn, max: mx }
      end
  end

  # Single-pass fused per-category boolean all / any, cached. Nil unless the
  # value data type is boolean (fall back to per_category, which raises like
  # CArray#all on a non-boolean).
  def all_any
    return @all_any if defined?(@all_any)
    @all_any =
      if @grouped.data_type == CA_BOOLEAN
        a = CArray.boolean(@k)
        o = CArray.boolean(@k)
        @grouped.send(:__reduceat_all_any__, @offsets, a, o)
        { all: a, any: o }
      end
  end

  # Build a length-k typed output by folding each category's members with the
  # given reduction block.  Fallback path (order statistics, and monoids on a
  # non-numeric value data type): each group is delegated to the same CArray
  # reduction, so the per-group result matches `CArray#<reduction>` over that
  # group's members — the mask carries the "insufficient present data" contract
  # for free (an all-masked group reduces like an empty one; identity-bearing
  # reductions return their identity, ratios return UNDEF; see ext ERI).
  def per_category (data_type)
    out = CArray.new(data_type, [@k])
    @k.times { |c| out[c] = yield(group_slice(c)) }
    out
  end
end


class CArray
  # @overload group_by_category(cat)
  #   Returns a {CACategoricalIterator} that reduces `self` (the payload)
  #   per category of `cat`.  Requires `self.elements == cat.elements`.
  #   @param cat [CACategorical] the classifier.
  #   @return [CACategoricalIterator]
  #   @raise [ArgumentError] when element counts differ.
  def group_by_category (cat)
    CACategoricalIterator.new(self, cat)
  end

  # @overload group_by_run
  #   Segments `self` into maximal runs of consecutive non-masked cells and
  #   returns a {CACategoricalIterator} that reduces each run as one category,
  #   ordered by position.  The run boundary is the mask: a masked cell belongs
  #   to no run and breaks any run across it.  State what separates runs (the
  #   "background") by masking before the call — e.g. `ca.mask_where(:le, 0)`
  #   makes non-positive cells background without mutating `ca`.  A series with
  #   no present cell yields zero groups rather than raising.  1-D only.
  #
  #   ```ruby
  #   prec = CA_DOUBLE([1,2,2,2,0,0,0,2,1,2,0,0,0,3,2,3,2,1,0,0,0])
  #   grp  = prec.mask_where(:le, 0).group_by_run
  #   grp.sum     # => [7.0, 5.0, 11.0]   per-run accumulation
  #   grp.count   # => [4, 3, 5]          per-run length
  #   grp.each { |members| ... }          # each run as a CArray
  #   ```
  #
  #   The run categories are labelled by their 0-based run index, so
  #   `grp.labels` is `[0, 1, ...]` in position order.
  #
  #   @return [CACategoricalIterator] one category per run, in order.
  #   @raise [RuntimeError] when `self` is not 1-D.
  def group_by_run
    raise "group_by_run: 1-D only (got #{ndim}-D)" unless ndim == 1
    if elements == 0
      code = CArray.int64(0)
    else
      present = is_not_masked
      edge    = present & present.shift(1).not   # rising edge = run start
      # feed cumsum via a zero-copy int8 reinterpret of the 1-byte booleans
      # rather than widening to int64; cumsum promotes to float64, so the
      # running count never overflows int8.
      code    = edge.refer(:int8).cumsum.int64 - 1   # 0-based run index per cell
      code[present.not] = UNDEF                  # masked cells join no run
    end
    # categorize turns the dense run indices into the run categories: it derives
    # the label vocabulary and folds an all-masked (dry) series to zero groups
    # on its own, so no explicit run count is needed here. code is monotonic (a
    # cumsum), so categorize's first-appearance order is already run order and
    # sort_labels would be a no-op.
    group_by_category(code.categorize)
  end
end

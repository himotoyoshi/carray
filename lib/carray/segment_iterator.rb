# ----------------------------------------------------------------------------
#
#  carray/segment_iterator.rb
#
#  CASegmentIterator -- reductions over consecutive segments of a flat
#  sequence.  The pieces are contiguous runs of a held, contiguous copy
#  (`grouped`), cut at the boundaries in @bounds (every boundary, k+1) and
#  @offsets (the starts, k, the form the reduceat kernels read).  Each
#  reduction is the core reduction lifted to the piece.
#
#  CACategoricalIterator is this iterator over a category-sorted copy: it
#  builds `grouped` by a counting sort and adds the labels and the
#  per-fiber (axis:) form.  A segment iterator has no axis: form; the
#  hooks at the bottom say so where a reduction is asked for one.
#
# ----------------------------------------------------------------------------

require "carray"

class CASegmentIterator < CAIterator

  # value   : the CArray whose segments are reduced, read in flatten order.
  # offsets : the k+1 boundaries (segment c spans offsets[c]...offsets[c+1]),
  # lengths : or the k lengths, the segments then starting at cell 0.
  #
  # Takes a copy of the cells the segments cover, so the reductions answer
  # about the values as they were at construction.  Cells before offsets[0]
  # or from offsets[-1] on belong to no segment.
  def initialize (value, offsets: nil, lengths: nil)
    kw = {}
    kw[:offsets] = offsets unless offsets.nil?
    kw[:lengths] = lengths unless lengths.nil?
    bounds = CArray.__segment_bounds__("segments", **kw)
    origin, finish = bounds[0], bounds[-1]
    if origin < 0 || finish > value.elements
      raise ArgumentError,
            "segments: the segments span #{origin}...#{finish}, " \
            "outside the #{value.elements} elements of the value"
    end
    @value     = value
    @src_shape = value.shape
    @k         = bounds.elements - 1
    @ndim      = 1
    @shape     = [@k]
    @origin    = origin
    @bounds    = bounds - origin                     # every boundary, from 0
    @offsets   = @bounds[0...-1].copy                # the starts, for the kernels
    @elements  = @k > 0 ? (@bounds[1..-1] - @bounds[0...-1]) : CArray.int64(0)
    @grouped   = finish > origin ? value.reshape(value.elements)[origin...finish].copy
                                 : CArray.new(value.data_type, [0])
    @empty     = CArray.new(@grouped.data_type, [0])
  end

  # @overload inspect
  #   Returns a one-line summary: the number of segments and their lengths.
  #   @return [String]
  def inspect
    "#<#{self.class} segments=#{@k} elements=#{@elements.to_a.inspect}>"
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

  # @overload elements
  #   Returns per-group cell counts (classified cells, including value-masked
  #   ones; = `cat.category_sizes`), a length-ngroups CArray aligned to
  #   {#labels}. The CAIterator count-family member — `CArray#elements`
  #   (structural, mask-independent) lifted per group.
  #   @return [CArray]
  def elements
    # A copy, like every other member that reads off a memo: the memo is the
    # iterator's own state, and handing out the array itself lets a caller
    # write into it and change what the iterator answers from then on. This
    # one invites it -- the docs point at its prefix sum for splitting a
    # column apart, which reads as scratch.
    counts.copy
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
    return axis_counts(axis) if axis
    m = moments
    m ? m[:count].copy : per_category(CA_INT64) { |s| s.count_not_masked }
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
            "#{self.class}#count(v, axis:) is not implemented — " \
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
            "#{self.class}#count_masked(axis:) is not implemented — " \
            "call it without axis:."
    end
    m = moments
    m ? counts - m[:count] : per_category(CA_INT64) { |s| s.count_masked }
  end

  # @overload sum
  #   Returns per-category sums in the data type `CArray#sum` promotes the value
  #   to (float64 for an integer value).  `accumulate` is the same fold kept in
  #   the value's own type.  An empty or fully-masked category sums the empty
  #   set, which is the additive identity `0` (unmasked) — the same contract as
  #   `CArray#sum` on an empty / all-masked array.
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
    return per_category(core_reduce_type(:sum)) { |s| s.sum } unless m
    m[:sum].copy                    # the moments sum IS the core fold (empty -> 0.0)
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
    return axis_by_masked_copy(axis, :accumulate, core_reduce_type(:accumulate)) if axis
    per_category(core_reduce_type(:accumulate)) { |s| s.accumulate }
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
    m ? m[:max].copy : per_category(core_reduce_type(:max)) { |s| s.max }
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
    m ? m[:min].copy : per_category(core_reduce_type(:min)) { |s| s.min }
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
    return per_category(core_reduce_type(:mean)) { |s| s.mean } unless m
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
    unless MONOID_TYPES.include?(grouped.data_type)
      return per_category(core_reduce_type(:percentile, p)) { |s| s.percentile(p) }
    end
    out = CArray.float64(@k)
    grouped.send(:__reduceat_percentile__, @offsets, p.to_f, out)
    out
  end

  # @overload quantile
  #   Returns the per-category five-number summary `[min, Q1, median, Q3, max]`
  #   as five length-k float64 CArrays (matching `CArray#quantile`): the
  #   percentiles at 0 / 25 / 50 / 75 / 100. Empty / all-masked categories are
  #   MASKED. For a single fraction q in 0..1 use `percentile(q * 100)`.
  #   @return [Array<CArray>]
  def quantile
    unless MONOID_TYPES.include?(grouped.data_type)
      return [0, 25, 50, 75, 100].map { |p| percentile(p) }
    end
    outs = Array.new(5) { CArray.float64(@k) }
    grouped.send(:__reduceat_quantile__, @offsets, *outs)
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
    return per_category(core_reduce_type(:variance)) { |s| s.variance } unless m
    cnt   = m[:count]
    means = m[:sum] / cnt.float64    # per-segment mean (garbage where count 0/1,
    out   = CArray.float64(@k)       #   ignored by the kernel's n<2 guards)
    grouped.send(:__reduceat_variance__, @offsets, means, cnt, out)
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
    return per_category(core_reduce_type(:stddev)) { |s| s.stddev } unless m
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
    return per_category(core_reduce_type(:prod)) { |s| s.prod } unless MONOID_TYPES.include?(grouped.data_type)
    out = CArray.float64(@k)
    grouped.send(:__reduceat_prod__, @offsets, out)
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
  #   from one moments pass.
  #   @return [Array<CArray>]
  # @overload minmax(axis:)
  #   Per-fiber `[min_ca, max_ca]` along `axis` (each shape [K, ...band], h's data type,
  #   empty group cells MASKED).  Ruby Array of two CArrays, not stacked.
  #   Both come from one kernel run.
  #   @param axis [Integer]
  #   @return [Array<CArray>]
  def minmax(axis: nil)
    if axis
      # take both off one pass rather than asking min and max separately,
      # which would run the kernel twice now that nothing is kept between
      # calls -- this is the "keep the result" the axis: family expects
      m = axis_moments(axis)
      return [m[:min], m[:max]]
    end
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
    return per_category(core_reduce_type(:variancep)) { |s| s.variancep } unless m
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
    return per_category(core_reduce_type(:stddevp)) { |s| s.stddevp } unless m
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
    am ? am[:min].copy : per_category(CA_INT64) { |s| s.min_index }
  end

  # @overload max_index
  #   Per-category group-local index of the maximum. See {#min_index}.
  #   @return [CArray] length-k int64
  def max_index
    am = arg_minmax
    am ? am[:max].copy : per_category(CA_INT64) { |s| s.max_index }
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
    out = CArray.int64(grouped.elements)
    @k.times do |c|
      lo, hi = @bounds[c], @bounds[c + 1]
      next unless hi > lo
      # View-local sort order of the segment (0..size-1), lifted to grouped
      # slots, then mapped back to source addresses via perm.
      out[lo...hi] = perm[grouped[lo...hi].sort_addr + lo]
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
    return kernel_weighted(wg)[0] if MONOID_TYPES.include?(grouped.data_type)
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
    return kernel_weighted(wg)[1] if MONOID_TYPES.include?(grouped.data_type)
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
    dt = data_type || grouped.data_type
    # Apply the block per category, assembled in grouped (category-contiguous)
    # order: a same-length result scatters cell for cell, a scalar broadcasts.
    transformed = CArray.new(dt, [grouped.elements])
    @k.times do |c|
      lo, hi = @bounds[c], @bounds[c + 1]
      transformed[lo...hi] = yield(grouped[lo...hi]) if hi > lo
    end
    # Scatter back to source positions via the permutation (grouped-order source
    # indices). Excluded cells are absent from perm and stay UNDEF.
    out = CArray.new(dt, @src_shape)
    out[] = UNDEF
    out.reshape(codes.elements)[perm] = transformed
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

  # @!method cumsum
  #   Per-category inclusive running sum (float64), source-shaped.
  #   @return [CArray]
  # @!method cumprod
  #   Per-category inclusive running product (float64), source-shaped.
  #   @return [CArray]
  # @!method cummax
  #   Per-category inclusive running maximum (value data type), source-shaped.
  #   @return [CArray]
  # @!method cummin
  #   Per-category inclusive running minimum (value data type), source-shaped.
  #   @return [CArray]
  # @!method cumcount
  #   Per-category 1-based within-category ordinal (int64), source-shaped.
  #   @return [CArray]
  [:cumsum, :cumprod, :cummax, :cummin, :cumcount].each do |op|
    define_method(op) { scan(op) }
  end

  private

  # The category-major copy every no-axis reduction works from. It does not
  # exist when the classifier does not line up cell-for-cell with the value;
  # such an iterator answers the per-fiber form only, and says so here rather
  # than letting a nil surface as whatever NoMethodError it reaches first.
  def grouped
    @grouped || raise(ArgumentError, @no_flat)
  end

  # Per-category cell counts, alongside #grouped and unavailable for the same
  # reason.
  def counts
    @elements || raise(ArgumentError, @no_flat)
  end

  # Drive a segment scan through the axis-group scan kernel: the whole value as
  # one grouped axis, the flat codes as the single bundle.  The kernel emits in
  # source order, so the flat result reshapes straight back to the source shape.
  def scan (op)
    scan_source.reshape(@value.elements)
               .__axis_group_scan__([0], [[codes, @k, [0]]], op)
               .reshape(*@src_shape)
  end

  # The values as they were when the iterator was built, in source order.
  # Every no-axis reduction works from the category-major copy taken then; the
  # scans read @value, so a write through the source between two calls used to
  # be visible to a cumsum and not to a sum, off one iterator.
  #
  # Rebuilt rather than copied a second time: @perm is exactly the classified
  # cells and @grouped holds their values and their masks, which is everything
  # a scan reads -- a cell classified by nothing is skipped on its code, before
  # its value is looked at. So this costs nothing until a scan asks for it, and
  # nothing at all for an iterator that never scans.
  def scan_source
    @scan_source ||=
      begin
        snap = @value.template
        snap.reshape(snap.elements)[perm] = grouped
        snap
      end
  end


  # Permutation: perm[slot] = the source index whose value sits at that grouped
  # slot. This is the valid prefix of the categorical's cached sort_addr, sliced
  # at construction (the same counting sort that lays out @grouped), so #map /
  # #sort_addr / the *_addr reductions read it for free.
  def perm
    @perm ||= CArray.int64(grouped.elements).seq!(@origin)
  end

  # The segment each source cell belongs to, -1 for a cell outside every
  # segment.  Read by #map, the scans and the weighted reductions; built the
  # first time one of them asks, since the reductions do not need it.
  def codes
    @codes ||= begin
      c = CArray.int64(@value.elements).fill(-1)
      if grouped.elements > 0
        c[@origin...(@origin + grouped.elements)] =
          CArray.segment_index(offsets: @bounds)
      end
      c
    end
  end

  # Lay a per-cell weight array out in category-contiguous order (same layout as
  # @grouped), so wsum / wmean can pair each group's values with its weights.
  # Weights are coerced to float64; the same counting-sort scatter propagates
  # the weight mask and skips excluded cells, so wg lines up with @grouped.
  def scatter_weights (weights)
    unless weights.elements == codes.elements
      raise ArgumentError,
            "wsum/wmean: weights.elements (#{weights.elements}) != " \
            "value.elements (#{codes.elements})"
    end
    wf = weights.float64
    wg = CArray.float64(grouped.elements)
    codes.send(:__categorical_scatter__, wf.reshape(wf.elements),
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
    grouped.send(:__reduceat_wsum_wmean__, @offsets, wg, ws, wm)
    [ws, wm]
  end

  # Per-group weighted fallback for non-numeric value data types (complex): delegate
  # each group to CArray#wsum / #wmean. Empty segments take the given identity.
  def fold_weighted (wg, empty)
    out = CArray.float64(@k)
    @k.times do |c|
      lo, hi = @bounds[c], @bounds[c + 1]
      out[c] = hi > lo ? yield(grouped[lo...hi], wg[lo...hi]) : empty
    end
    out
  end

  # The members of category `c` as a CArray slice of the grouped copy.  An empty
  # category (zero-width segment) yields the shared empty array — a zero-length
  # slice cannot be taken directly, and an empty array carries the same reduction
  # contract we want (identity for sum, UNDEF for ratios).
  def group_slice (c)
    lo, hi = @bounds[c], @bounds[c + 1]
    hi > lo ? grouped[lo...hi] : @empty
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
      if MONOID_TYPES.include?(grouped.data_type)
        dt     = grouped.data_type
        counts = CArray.int64(@k)
        sums   = CArray.float64(@k)
        mins   = CArray.new(dt, [@k])
        maxs   = CArray.new(dt, [@k])
        grouped.send(:__reduceat_moments__, @offsets, counts, sums, mins, maxs)
        { count: counts, sum: sums, min: mins, max: maxs }
      end
  end

  # Single-pass fused group-local argmin / argmax (min_index / max_index),
  # cached. Nil for a non-numeric value data type (fall back to per_category).
  def arg_minmax
    return @arg_minmax if defined?(@arg_minmax)
    @arg_minmax =
      if MONOID_TYPES.include?(grouped.data_type)
        mn = CArray.int64(@k)
        mx = CArray.int64(@k)
        grouped.send(:__reduceat_argminmax__, @offsets, mn, mx)
        { min: mn, max: mx }
      end
  end

  # Single-pass fused per-category boolean all / any, cached. Nil unless the
  # value data type is boolean (fall back to per_category, which raises like
  # CArray#all on a non-boolean).
  def all_any
    return @all_any if defined?(@all_any)
    @all_any =
      if grouped.data_type == CA_BOOLEAN
        a = CArray.boolean(@k)
        o = CArray.boolean(@k)
        grouped.send(:__reduceat_all_any__, @offsets, a, o)
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
  # The data type the core reduction `op` promotes this value to.  Asked of the
  # core itself -- a one-cell reduction of the value's type -- rather than
  # restated here, so a per-category answer cannot drift from `CArray#<op>`
  # (`sum` on an integer promotes, `accumulate` stays, `min` / `max` keep the
  # type but a boolean widens, `prod` on an object stays an object).  A payload
  # the core refuses to fold this way raises here, with the core's own error.
  # Probes the core with a one-cell array of the value's data type and takes
  # the answer's. Asks @value rather than the grouped copy, which has the same
  # data type but does not exist on an iterator that answers only the
  # per-fiber form -- and `accumulate(axis:)`, the one axis: member that needs
  # this, is exactly the case that would have found it missing.
  def core_reduce_type (op, *args)
    (@core_reduce_type ||= {})[[op, args]] ||=
      @value.face? && @value.elements.zero? ?
        CA_OBJECT : core_probe.public_send(op, *args, axis: 1).data_type
  end

  # A one-cell array of the same kind as the values, so the core answers about
  # the same thing the group slices will hand back. For a Face that is a view
  # of the values themselves rather than a blank: a Face cannot be allocated
  # from its surface data type alone, and a blank storage array is not a valid
  # Face for every one of them -- a const string's record indexes a shared
  # pool, so a zeroed record points nowhere.
  def core_probe
    return CArray.new(@value.data_type, [1, 1]) unless @value.face?
    @value.reshape(@value.elements)[[0]].reshape(1, 1)
  end

  # Whether an output can be built by lifting one. A Face is filled by writing
  # surface values into storage, so this needs a Face that can be written
  # into; a read-only one -- a const string's records index a shared pool, a
  # categorical's codes index a vocabulary -- has no blank form to fill.
  def face_output?
    @value.face? && ! @value.read_only?
  end

  def per_category (data_type)
    out = if ! @value.face? || data_type != @value.data_type
            CArray.new(data_type, [@k])
          elsif face_output?
            # the core answered in the values' own Face, so the output is one
            # too: CATime#min hands back a CATime::Element, which only a
            # CATime has anywhere to put
            CArray.new(@value.parent.data_type, [@k],
                       bytes: @value.parent.bytes).face_lift(@value)
          else
            # a read-only Face cannot be filled, so its answers are collected
            # as the surface objects they already are
            CArray.new(CA_OBJECT, [@k])
          end
    # A member the core refuses for this Face still refuses: the group slice is
    # the Face, so the refusal comes from there, in the core's own words.
    @k.times { |c| out[c] = yield(group_slice(c)) }
    out
  end

  # ---- no axis: form -------------------------------------------------------

  def axis_by_masked_copy (*)
    raise NotImplementedError, "#{self.class} has no axis: form"
  end

  def axis_counts (*)
    raise NotImplementedError, "#{self.class} has no axis: form"
  end

  def axis_mean (*)
    raise NotImplementedError, "#{self.class} has no axis: form"
  end

  def axis_moments (*)
    raise NotImplementedError, "#{self.class} has no axis: form"
  end

  def axis_order_stat_defer! (*)
    raise NotImplementedError, "#{self.class} has no axis: form"
  end

  def axis_prod (*)
    raise NotImplementedError, "#{self.class} has no axis: form"
  end

  def axis_sum (*)
    raise NotImplementedError, "#{self.class} has no axis: form"
  end

  def axis_wsum_wmean (*)
    raise NotImplementedError, "#{self.class} has no axis: form"
  end

end


class CArray
  # @overload segments(offsets:)
  #   Returns a {CASegmentIterator} that reduces `self` segment by segment,
  #   segment `c` being the cells `offsets[c]...offsets[c + 1]` in flatten
  #   order.  Cells outside `offsets[0]...offsets[-1]` belong to no segment.
  #
  #     data.segments(offsets: [0, 2, 2, 5]).sum   # one sum per segment
  #
  #   @param offsets [CArray, Array<Integer>] `k + 1` non-decreasing
  #     boundaries within `0..elements`.
  #   @return [CASegmentIterator]
  # @overload segments(lengths:)
  #   The same from the `k` segment lengths, the first segment starting at
  #   cell 0.
  #   @param lengths [CArray, Array<Integer>] one count per segment.
  #   @return [CASegmentIterator]
  # @raise [ArgumentError] for decreasing or empty offsets, a negative or
  #   masked length, segments reaching outside `self`, or unless exactly one
  #   of `offsets:` and `lengths:` is given.
  def segments (offsets: nil, lengths: nil)
    CASegmentIterator.new(self, offsets: offsets, lengths: lengths)
  end
end

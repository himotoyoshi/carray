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

# A CAIterator over consecutive segments of a flat sequence, built by
# {CArray#segments}.  Segment `c` is the cells `offsets[c]...offsets[c + 1]`
# of the value read in flatten order, and each reduction answers one value
# per segment -- the core reduction of the same name, lifted to the segment,
# with the core's data types and its answer for an empty or all-masked
# segment.  The pieces never overlap, so {#map} and the running scans are
# available too.
#
# The iterator holds a copy of the covered cells, taken at construction.
# Cells outside `offsets[0]...offsets[-1]` belong to no segment: they are
# UNDEF in {#map} and in the scans.
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
  #   Yields each segment's members in order, as a CArray slice of the held
  #   copy; an empty segment yields an empty array.  Without a block, returns
  #   an Enumerator.
  #   @yieldparam members [CArray]
  #   @return [Enumerator, self]
  def each
    return to_enum(:each) unless block_given?
    @k.times { |c| yield segment_slice(c) }
    self
  end

  # @overload elements
  #   Returns the number of cells in each segment, masked or not. The
  #   CAIterator count-family member — `CArray#elements` (structural,
  #   mask-independent) lifted per segment.
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
  #   Returns the per-segment count of present (non-masked) values as int64
  #   — the denominator the value reductions actually divide by.  Equals
  #   {#elements} unless the value carries a mask.  A count is always defined,
  #   so an empty segment is `0` (never masked).
  #   @return [CArray]
  def count_not_masked(axis: nil)
    return axis_counts(axis) if axis
    m = moments
    m ? m[:count].copy : per_segment(CA_INT64) { |s| s.count_not_masked }
  end

  # @overload count(v = <none>)
  #   Per-segment count, mirroring `CArray#count` per segment. No argument
  #   returns {#count_not_masked} (present cells); `count(UNDEF)` returns
  #   {#count_masked}; `count(v)` counts cells whose value equals `v`.
  #   @return [CArray] length-k int64
  def count (*args, axis: nil)
    if axis
      return count_not_masked(axis: axis) if args.empty?
      raise NotImplementedError,
            "#{self.class}#count(v, axis:) is not implemented — " \
            "value-equality count is available without axis:."
    end
    return count_not_masked if args.empty?
    # Delegate per segment to CArray#count (handles count(UNDEF) -> masked count and
    # count(v) alike, with core's exact data type equality). The segment slice is a
    # CABlock, whose own #count is the block geometry accessor, so dispatch
    # CArray#count explicitly. (Not fused: a value-equality reduceat would have
    # to reproduce core's cross-type / out-of-range equality exactly.)
    cnt = CArray.instance_method(:count)
    per_segment(CA_INT64) { |s| cnt.bind_call(s, *args) }
  end

  # @overload count_masked
  #   Returns the per-segment count of masked (missing) values as int64.
  #   Empty segments are `0`.
  #   @return [CArray]
  def count_masked(axis: nil)
    if axis
      raise NotImplementedError,
            "#{self.class}#count_masked(axis:) is not implemented — " \
            "call it without axis:."
    end
    m = moments
    m ? counts - m[:count] : per_segment(CA_INT64) { |s| s.count_masked }
  end

  # @overload sum
  #   Returns per-segment sums in the data type `CArray#sum` promotes the value
  #   to (float64 for an integer value).  `accumulate` is the same fold kept in
  #   the value's own type.  An empty or fully-masked segment sums the empty
  #   set, which is the additive identity `0` (unmasked) — the same contract as
  #   `CArray#sum` on an empty / all-masked array.
  #   @return [CArray]
  def sum(axis: nil)
    return axis_sum(axis) if axis
    m = moments
    return per_segment(core_reduce_type(:sum)) { |s| s.sum } unless m
    m[:sum].copy                    # the moments sum IS the core fold (empty -> 0.0)
  end

  # @overload accumulate
  #   Returns per-segment sums folded in the value's own data type, wrapping at
  #   its width, as the core `accumulate` does.  This is the exact in-type fold:
  #   `sum` reads its answer off a float64 moment and casts back, so it loses
  #   the low bits of a wide integer payload and does not wrap.  An empty or
  #   fully-masked segment accumulates the empty set, the additive identity `0`
  #   (unmasked).
  #   @return [CArray]
  def accumulate(axis: nil)
    return axis_by_masked_copy(axis, :accumulate, core_reduce_type(:accumulate)) if axis
    per_segment(core_reduce_type(:accumulate)) { |s| s.accumulate }
  end

  # @overload max
  #   Returns per-segment maxima in the value data type.  Empty segments are
  #   MASKED.
  #   @return [CArray]
  def max(axis: nil)
    return axis_moments(axis)[:max] if axis
    m = moments
    m ? m[:max].copy : per_segment(core_reduce_type(:max)) { |s| s.max }
  end

  # @overload min
  #   Returns per-segment minima in the value data type.  Empty segments are
  #   MASKED.
  #   @return [CArray]
  def min(axis: nil)
    return axis_moments(axis)[:min] if axis
    m = moments
    m ? m[:min].copy : per_segment(core_reduce_type(:min)) { |s| s.min }
  end

  # @overload mean
  #   Returns per-segment means as float64.  Empty segments are MASKED.
  #   @return [CArray]
  def mean(axis: nil)
    return axis_mean(axis) if axis
    m = moments
    return per_segment(core_reduce_type(:mean)) { |s| s.mean } unless m
    cnt = m[:count]
    out = m[:sum] / cnt.float64      # count 0 -> NaN, masked next
    out[cnt.eq(0)] = UNDEF           # empty / all-masked category -> MASKED
    out
  end

  # @overload median
  #   Returns per-segment medians as float64.  Empty segments are MASKED.
  #   @return [CArray]
  def median(axis: nil)
    axis_order_stat_defer!(:median) if axis
    percentile(50.0)
  end

  # @overload percentile(p)
  #   Returns the per-segment `p`-th percentile as float64 (`p` in 0..100,
  #   `:linear` interpolation, matching `CArray#percentile`).  Empty segments
  #   are MASKED.  Order statistics need every value of a segment held together —
  #   this is the reduceat that only the eager grouped copy can serve.
  #   @param p [Numeric] percentile in 0..100.
  #   @return [CArray]
  def percentile (p, axis: nil)
    axis_order_stat_defer!(:percentile) if axis
    unless MONOID_TYPES.include?(grouped.data_type)
      return per_segment(core_reduce_type(:percentile, p)) { |s| s.percentile(p) }
    end
    out = CArray.float64(@k)
    grouped.send(:__reduceat_percentile__, @offsets, p.to_f, out)
    out
  end

  # @overload quantile
  #   Returns the per-segment five-number summary `[min, Q1, median, Q3, max]`
  #   as five length-k float64 CArrays (matching `CArray#quantile`): the
  #   percentiles at 0 / 25 / 50 / 75 / 100. Empty / all-masked segments are
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
  #   Returns per-segment SAMPLE variance (ddof=1) as float64.  Matches
  #   `CArray#variance` per segment: an empty or fully-masked segment is MASKED,
  #   a single-value segment is `0.0` (CArray's n=1 contract), n>=2 is the
  #   sample variance.
  #   @return [CArray]
  def variance(axis: nil)
    return axis_by_masked_copy(axis, :variance) if axis
    m = moments
    return per_segment(core_reduce_type(:variance)) { |s| s.variance } unless m
    cnt   = m[:count]
    means = m[:sum] / cnt.float64    # per-segment mean (garbage where count 0/1,
    out   = CArray.float64(@k)       #   ignored by the kernel's n<2 guards)
    grouped.send(:__reduceat_variance__, @offsets, means, cnt, out)
    out
  end

  # @overload stddev
  #   Returns per-segment SAMPLE standard deviation (ddof=1) as float64.
  #   Matches `CArray#stddev` per segment (empty / all-masked MASKED,
  #   single-value `0.0`).
  #   @return [CArray]
  def stddev(axis: nil)
    return axis_by_masked_copy(axis, :stddev) if axis
    m = moments
    return per_segment(core_reduce_type(:stddev)) { |s| s.stddev } unless m
    variance.sqrt                    # sqrt propagates the n=0 mask
  end

  # @overload prod
  #   Returns per-segment products as float64 (matching `CArray#prod`). An
  #   empty / fully-masked segment is `1.0` (the multiplicative identity).
  #   Single-pass reduceat for numeric values; per-segment fallback otherwise.
  #   @return [CArray]
  def prod(axis: nil)
    return axis_prod(axis) if axis
    return per_segment(core_reduce_type(:prod)) { |s| s.prod } unless MONOID_TYPES.include?(grouped.data_type)
    out = CArray.float64(@k)
    grouped.send(:__reduceat_prod__, @offsets, out)
    out
  end

  # @overload all
  #   Returns the per-segment `all` as boolean (matching `CArray#all`): true
  #   iff every present value is truthy (empty segment -> true, vacuously).
  #   The value data type must be boolean, as for `CArray#all`.
  #   @return [CArray]
  def all
    aa = all_any
    aa ? aa[:all] : per_segment(CA_BOOLEAN) { |s| s.all }
  end

  # @overload any
  #   Returns the per-segment `any` as boolean (matching `CArray#any`): true
  #   iff some present value is truthy (empty segment -> false). The value
  #   data type must be boolean, as for `CArray#any`.
  #   @return [CArray]
  def any
    aa = all_any
    aa ? aa[:any] : per_segment(CA_BOOLEAN) { |s| s.any }
  end

  # ---- tier 2 (fused / population / position) ------------------------------

  # @overload minmax
  #   Returns the per-segment `[min, max]` pair (each a length-k CArray in the
  #   value data type; empty segments MASKED), matching `CArray#minmax`. Both come
  #   from one moments pass.
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
  #   Per-segment POPULATION variance (ddof=0) as float64, matching
  #   `CArray#variancep`: empty / all-masked -> MASKED, single value -> 0.0.
  #   Derived from the sample variance (variancep = variance * (n-1) / n), so it
  #   reuses the centred two-pass kernel with no extra walk.
  #   @return [CArray]
  def variancep(axis: nil)
    return axis_by_masked_copy(axis, :variancep) if axis
    m = moments
    return per_segment(core_reduce_type(:variancep)) { |s| s.variancep } unless m
    cnt = m[:count]
    vp  = variance * (cnt - 1).float64 / cnt.float64
    vp[cnt.eq(0)] = UNDEF                 # empty / all-masked stays masked
    vp
  end

  # @overload stddevp
  #   Per-segment POPULATION standard deviation (ddof=0) as float64.
  #   @return [CArray]
  def stddevp(axis: nil)
    return axis_by_masked_copy(axis, :stddevp) if axis
    m = moments
    return per_segment(core_reduce_type(:stddevp)) { |s| s.stddevp } unless m
    variancep.sqrt
  end

  # @overload min_index
  #   Per-segment index of the minimum — the position within the
  #   segment's members (source order) — matching `CArray#min_index` per segment.
  #   Empty / all-masked segments are MASKED. Single-pass fused reduceat for
  #   numeric values; per-segment fallback otherwise.
  #   @return [CArray] length-k int64
  def min_index
    am = arg_minmax
    am ? am[:min].copy : per_segment(CA_INT64) { |s| s.min_index }
  end

  # @overload max_index
  #   Per-segment index of the maximum. See {#min_index}.
  #   @return [CArray] length-k int64
  def max_index
    am = arg_minmax
    am ? am[:max].copy : per_segment(CA_INT64) { |s| s.max_index }
  end

  # @overload min_addr
  #   Per-segment flat source address of the minimum — which cell of the source
  #   value holds it, matching `CArray#min_addr` per segment. Unlike {#min_index}
  #   (the position within the segment) this indexes back into the original array
  #   (`value.reshape(value.elements)[grp.min_addr]`). Empty segments MASKED.
  #   @return [CArray] length-k int64
  def min_addr
    segment_addr(min_index)
  end

  # @overload max_addr
  #   Per-segment flat source address of the maximum. See {#min_addr}.
  #   @return [CArray] length-k int64
  def max_addr
    segment_addr(max_index)
  end

  # @overload sort_addr
  #   Per-segment sort by flat source address. Returns a length-nvalid
  #   (= `elements.sum`) int64 CArray of the flat SOURCE addresses that sort each
  #   segment's members, segment by segment: part `c` holds segment `c`'s
  #   source addresses in ascending-value order, parts concatenated in
  #   order. So `value.reshape(value.elements)[grp.sort_addr]` yields
  #   the values segment by segment, sorted within each, and splitting by the
  #   {#elements} prefix sum gives per-segment. Excluded cells (in no segment) are
  #   omitted. A masked value sorts to the tail of its segment (as `CArray#sort`
  #   sends masked cells to the end), so with a mask the first address is the
  #   minimum but the last is the masked cell, not the maximum.
  #
  #   Unlike {#min_index} / {#max_index} (positions within a segment), this
  #   indexes back into the original array; only the source-address form is
  #   offered, mirroring {#min_addr}.
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
  #   Per-segment weighted sum as float64, matching `CArray#wsum`. `weights` is
  #   a per-cell weight CArray in the source order (same elements as the value).
  #   Empty / all-masked segment -> 0.0 (the additive identity). A cell is
  #   skipped iff its value OR its weight is masked (core's contract).
  #   @param weights [CArray]
  #   @return [CArray]
  def wsum (weights, axis: nil)
    return axis_wsum_wmean(weights, axis)[0] if axis
    wg = scatter_weights(weights)
    return kernel_weighted(wg)[0] if MONOID_TYPES.include?(grouped.data_type)
    fold_weighted(wg, 0.0) { |v, ws| v.wsum(ws) }
  end

  # @overload wmean(weights)
  #   Per-segment weighted mean as float64, matching `CArray#wmean`. Empty
  #   segment -> MASKED; a present segment whose weights sum to zero -> NaN
  #   (core's 0/0 contract).
  #   @param weights [CArray]
  #   @return [CArray]
  def wmean (weights, axis: nil)
    return axis_wsum_wmean(weights, axis)[1] if axis
    wg = scatter_weights(weights)
    return kernel_weighted(wg)[1] if MONOID_TYPES.include?(grouped.data_type)
    fold_weighted(wg, UNDEF) { |v, ws| v.wmean(ws) }
  end

  # @overload reduce { |members| ... }
  #   Custom per-segment reduction (the escape hatch for statistics not in the
  #   named surface), mirroring `CArray#reduce_slab`. The block receives each
  #   segment's members (a CArray) and returns one value per segment.
  #   @yieldparam members [CArray]
  #   @return [CArray] length-k
  # @overload reduce(init) { |acc, elem| ... }
  #   Per-segment fold: each segment's members are folded element by
  #   element starting from `init`.
  #   @param init [Object] initial accumulator.
  #   @return [CArray] length-k
  def reduce (*args, data_type: nil, &blk)
    raise LocalJumpError, "no block given (yield)" unless blk
    dt = data_type || CA_OBJECT
    if args.empty?
      per_segment(dt) { |s| blk.call(s) }
    else
      init = args[0]
      per_segment(dt) { |s|
        acc = init
        s.each { |e| acc = blk.call(acc, e) }
        acc
      }
    end
  end

  # @overload map(data_type: nil) { |members| ... }
  #   Segment-wise element-wise transform, mirroring `CArray#map_slab`. The block
  #   receives each segment's members and returns either a same-length CArray
  #   (scattered back cell for cell) or a scalar (broadcast over the segment's
  #   cells). Returns a NEW CArray shaped like the source `value`; the original
  #   is not modified (`value[] = grp.map { ... }` for in-place). Excluded cells
  #   (in no segment) are UNDEF in the result.
  #   @yieldparam members [CArray]
  #   @return [CArray] shaped like the source value
  def map (data_type: nil)
    raise LocalJumpError, "no block given (yield)" unless block_given?
    dt = data_type || grouped.data_type
    # Apply the block per segment, assembled in grouped (segment-contiguous)
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

  # ---- segment scan: within-segment running statistics ------------------
  #
  # The per-element-emit siblings of the reductions: unlike a reduction (which
  # collapses each segment to one value) a scan preserves the source shape,
  # each cell holding its segment's running statistic up to and including that
  # cell, in source (row-major) order.  A segment is a partition (each cell is
  # in at most one segment), so the running value is single-valued.  Each
  # routes straight through the fused C kernel __axis_group_scan__ (the same one
  # CAGroupIterator drives) with the whole source as a single grouped axis and
  # the segment of each cell (#codes) as the single bundle -- which yields
  # SOURCE-ORDER output directly, so no inverse permutation is needed.
  # A cell in no segment is UNDEF.  A masked cell inside a segment holds the
  # running value, as `CArray#cumsum` does.  Mirroring the reductions (sum / mean), a scan
  # takes no axis argument.  cumsum / cumprod -> float64, cummax / cummin
  # preserve the value data type, cumcount -> int64 (1-based within-segment
  # ordinal); an object value data type is carried by the kernel's object branch.

  # @!method cumsum
  #   Per-segment inclusive running sum (float64), source-shaped.
  #   @return [CArray]
  # @!method cumprod
  #   Per-segment inclusive running product (float64), source-shaped.
  #   @return [CArray]
  # @!method cummax
  #   Per-segment inclusive running maximum (value data type), source-shaped.
  #   @return [CArray]
  # @!method cummin
  #   Per-segment inclusive running minimum (value data type), source-shaped.
  #   @return [CArray]
  # @!method cumcount
  #   Per-segment 1-based within-segment ordinal (int64), source-shaped.
  #   @return [CArray]
  [:cumsum, :cumprod, :cummax, :cummin, :cumcount].each do |op|
    define_method(op) { scan(op) }
  end

  private

  # The contiguous copy every reduction works from. On a CACategoricalIterator
  # it does not exist when the classifier does not line up cell-for-cell with the value;
  # such an iterator answers the per-fiber form only, and says so here rather
  # than letting a nil surface as whatever NoMethodError it reaches first.
  def grouped
    @grouped || raise(ArgumentError, @no_flat)
  end

  # Per-segment cell counts, alongside #grouped and unavailable for the same
  # reason.
  def counts
    @elements || raise(ArgumentError, @no_flat)
  end

  # Drive a segment scan through the axis-group scan kernel: the whole value as
  # one grouped axis, the flat codes as the single bundle.  The kernel emits in
  # source order, so the flat result reshapes straight back to the source shape.
  #
  # With no segment at all the kernel has no group to size, so it is given
  # one that no cell belongs to: every cell comes back UNDEF, as it does when
  # there are segments and a cell is in none of them.
  def scan (op)
    bundle = @k > 0 ? [codes, @k, [0]]
                    : [CArray.int64(@value.elements).fill(-1), 1, [0]]
    scan_source.reshape(@value.elements)
               .__axis_group_scan__([0], [bundle], op)
               .reshape(*@src_shape)
  end

  # The values as they were when the iterator was built, in source order.
  # Every no-axis reduction works from the contiguous copy taken then; the
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
  # slot, read by #map / #sort_addr / the *_addr reductions.  A segment's copy
  # is the source range itself, so this is a run of consecutive indices, built
  # the first time it is asked for.  (A CACategoricalIterator sets it at
  # construction: the valid prefix of the categorical's cached sort_addr.)
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

  # Lay a per-cell weight array out in segment-contiguous order (same layout as
  # @grouped), so wsum / wmean can pair each segment's values with its weights.
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

  # Map a per-segment index to the flat source address via the
  # permutation (grouped slot -> source index). The min/max sits at grouped slot
  # offsets[c] + local_index[c]; perm carries it back to the source. Empty
  # segments (masked local index) stay masked.
  def segment_addr (local_index)
    out = CArray.int64(@k)
    @k.times do |c|
      out[c] = local_index.is_masked[c] ? UNDEF
                                        : perm[@offsets[c] + local_index[c]]
    end
    out
  end

  # Fused per-segment weighted sum + weighted mean (one C pass over the grouped
  # copy, weights in segment order). Returns [wsum, wmean]; wmean is masked where a
  # segment has no present (value AND weight) pair. Numeric value data types only.
  def kernel_weighted (wg)
    ws = CArray.float64(@k)
    wm = CArray.float64(@k)
    grouped.send(:__reduceat_wsum_wmean__, @offsets, wg, ws, wm)
    [ws, wm]
  end

  # Per-segment weighted fallback for non-numeric value data types (complex): delegate
  # each segment to CArray#wsum / #wmean. Empty segments take the given identity.
  def fold_weighted (wg, empty)
    out = CArray.float64(@k)
    @k.times do |c|
      lo, hi = @bounds[c], @bounds[c + 1]
      out[c] = hi > lo ? yield(grouped[lo...hi], wg[lo...hi]) : empty
    end
    out
  end

  # The members of segment `c` as a CArray slice of the grouped copy.  An empty
  # segment (zero-width segment) yields the shared empty array — a zero-length
  # slice cannot be taken directly, and an empty array carries the same reduction
  # contract we want (identity for sum, UNDEF for ratios).
  def segment_slice (c)
    lo, hi = @bounds[c], @bounds[c + 1]
    hi > lo ? grouped[lo...hi] : @empty
  end

  # Single-pass reduceat moments (count / sum / min / max per segment), computed
  # once over the grouped copy and cached — the whole point of the eager copy is
  # that one scatter is followed by cheap single-pass reductions with no
  # per-segment views.  Nil for a non-numeric value data type (complex / object /
  # bool), where the monoid reductions fall back to per_segment.
  # numeric value data types the C moments kernel handles (int8..float64); bool /
  # complex / object fall back to per_segment.
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

  # Single-pass fused per-segment argmin / argmax (min_index / max_index),
  # cached. Nil for a non-numeric value data type (fall back to per_segment).
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

  # Single-pass fused per-segment boolean all / any, cached. Nil unless the
  # value data type is boolean (fall back to per_segment, which raises like
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

  # The data type the core reduction `op` promotes this value to.  Asked of the
  # core itself -- a one-cell reduction of the value's type -- rather than
  # restated here, so a per-segment answer cannot drift from `CArray#<op>`
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
  # the same thing the segment slices will hand back. For a Face that is a view
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

  # Build a length-k typed output by folding each segment's members with the
  # given reduction block.  Fallback path (order statistics, and monoids on a
  # non-numeric value data type): each segment is delegated to the same CArray
  # reduction, so the per-segment result matches `CArray#<reduction>` over that
  # segment's members — the mask carries the "insufficient present data" contract
  # for free (an all-masked segment reduces like an empty one; identity-bearing
  # reductions return their identity, ratios return UNDEF).
  def per_segment (data_type)
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
    # A member the core refuses for this Face still refuses: the segment slice is
    # the Face, so the refusal comes from there, in the core's own words.
    @k.times { |c| out[c] = yield(segment_slice(c)) }
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

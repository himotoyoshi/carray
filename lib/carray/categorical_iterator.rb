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
require "carray/segment_iterator"

# A CAIterator over the categories of a CACategorical.  CAIterator is the
# family base (the built-in iterators like CAWindowIterator / CABlockIterator
# are defined in C); a Ruby `Foo < CAIterator` supplies its own behaviour and
# does not lean on the base machinery.  Like CASlabIterator, this class defines
# its own `each` (over the k categories, yielding each category's member slice),
# which drives the inherited Enumerable surface; the reduction methods (sum /
# mean / median / ...) aggregate the groups into length-k arrays.  The kernels
# are per-category slices of an eager, category-contiguous grouped copy.  This
# supersedes the older CAClassIterator.
class CACategoricalIterator < CASegmentIterator

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
      nvalid    = counts.sum
      @offsets  = cat.reduceat_index                # cached segment STARTS (int64[k])
      @bounds   = CArray.segment_offsets(lengths: @elements)  # every boundary (int64[k+1])
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
      @empty    = CArray.new(grouped.data_type, [0])
    else
      # Shape mismatch: only per-fiber axis: dispatch could still work.  With a
      # 1-D value there is no fiber structure to broadcast into, so a mismatch
      # is unrecoverable (preserves the old strict check).  For higher-rank
      # value, defer validation to reduce time — check only that cat.ndim fits
      # one of the 3 axis: cases;
      # A no-axis reduce has no grouped buffer to work from. The reason is
      # recorded here and raised from wherever one is asked for, so what
      # surfaces names the mismatch instead of being whatever NoMethodError
      # the nil produced first.
      mismatch = "group_by_category: value.elements (#{value.elements}) != " \
                 "cat.elements (#{cat.elements})"
      if value.ndim == 1 ||
         ! [1, value.ndim - 1, value.ndim].include?(cat.ndim)
        raise ArgumentError,
              mismatch +
              (value.ndim == 1 ? "" :
                ". For per-fiber reduce use `.sum(axis: k)`; cat.ndim=" \
                "#{cat.ndim} must be 1 (case A), #{value.ndim} (case B), " \
                "or #{value.ndim - 1} (band-only) for h.ndim=#{value.ndim}.")
      end
      @no_flat = mismatch + ". This iterator answers only the per-fiber form, " \
                 "`.<reduce>(axis: k)`."
    end
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

  # Group-vocabulary alias for {#elements}; reads naturally next to
  # {#ngroups} and mirrors `CACategorical#category_sizes`.
  alias group_sizes elements

  # @overload inspect
  #   Returns a compact one-line summary — the group count, the label
  #   vocabulary, and the per-group cell counts — instead of dumping the
  #   internal grouped/value/codes buffers.
  #   @return [String]
  def inspect
    # An iterator that answers only the per-fiber form has no per-category
    # counts to show. Saying so beats both raising -- inspect is what you
    # reach for when something is already puzzling -- and printing an empty
    # list, which reads as a grouping that classified nothing.
    tail = @elements ? "elements=#{@elements.to_a.inspect}" : "per-fiber only"
    "#<#{self.class} ngroups=#{@k} labels=#{@labels.inspect} #{tail}>"
  end

  private

  # Axis-aware count of present cells. Counting how many cells fall in a
  # group does not look at what is in them, so it is taken from the codes and
  # the value's mask rather than from the fused moments kernel, which is
  # numeric-only and refused a complex, boolean or object payload for an
  # answer that never depended on the payload.
  def axis_counts (axis)
    h = @value
    unless axis.is_a?(Integer) && axis >= 0 && axis < h.ndim
      raise ArgumentError,
            "group_by_category.count(axis: #{axis.inspect}): axis must be an " \
            "Integer in [0, #{h.ndim}) for source h with shape #{h.shape}"
    end
    full_c  = resolve_axis_codes(@cat.codes, h.shape, axis)
    band    = h.shape.dup; band.delete_at(axis)
    out     = CArray.int64(*([@k] + band))
    present = h.has_mask? ? h.is_not_masked : nil
    slot    = [nil] * (band.size + 1)
    @k.times do |c|
      # a masked code belongs to no group, and eq yields UNDEF there
      belongs = full_c.eq(c)
      belongs = belongs.strip_mask(false) if belongs.has_mask?
      belongs = belongs & present if present
      slot[0] = c
      out[*slot] = belongs.int64.sum(axis: axis)
    end
    out
  end

  # Axis-aware moments (count / sum / min / max) via the fused per-fiber
  # scatter-reduce C kernel.  Returns
  # `{count: <int64>, sum: <float64>, min: <h's type, masked>, max: <h's type, masked>}`,
  # all shape [K, ...band].
  #
  # Read fresh on every call, deliberately.  It used to be kept per axis, and
  # since the rest of the axis: family (prod, the variance family, wsum /
  # wmean) reads the source when asked, half of the family answered about the
  # values as they were and half about the values as they are.  Writing
  # through another view of the source between two calls got you a mean of 2.0
  # beside a variance of 4704.5 for the same cell, which is not a pair any
  # data can produce.  The axis: path materialises nothing else, so holding
  # this one thing was the odd choice; a caller who wants a fused kernel's
  # four answers shares them by keeping the result.
  def axis_moments (axis)
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
    {count: counts, sum: sums, min: mins, max: maxs}
  end

  # Axis-aware sum: the moments sum is already the core fold in the core's own
  # type, so it is handed back as is (an empty group cell carries identity 0.0).
  def axis_sum (axis)
    axis_moments(axis)[:sum]
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
    # Chosen by shape, not by rank. For a 2-D source the case A shape and the
    # band-only shape are both rank 1, so choosing by rank took case A every
    # time and band-only could never be reached there -- while the refusal
    # went on to list the very shape it was refusing among the ones it
    # accepts. When both fit, which a square source makes possible, case A
    # wins: classifying along the reduce axis is the reading that holds at
    # every rank.
    case
    when codes.shape == [h_shape[axis]]                      # case A
      view_shape = Array.new(ndim, 1); view_shape[axis] = h_shape[axis]
      codes.reshape(*view_shape).broadcast_to(*h_shape)
    when codes.shape == h_shape                              # case B
      codes
    when codes.shape == band                                 # band-only
      view_shape = h_shape.dup; view_shape[axis] = 1
      codes.reshape(*view_shape).broadcast_to(*h_shape)
    else
      axis_shape_mismatch!(codes.shape, h_shape, axis, band)
    end
  end

  def axis_shape_mismatch! (cat_shape, h_shape, axis, band)
    # No method name: the one place that resolves this serves sum, mean, min,
    # max, count and the rest alike, and naming one of them would be wrong for
    # the others. The backtrace says which was called.
    raise ArgumentError,
          "group_by_category (axis: #{axis}): cat.shape=#{cat_shape.inspect} " \
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
      # a boolean cumsum counts in uint64, exactly
      code    = edge.cumsum.int64 - 1               # 0-based run index per cell
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

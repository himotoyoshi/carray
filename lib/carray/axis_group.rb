#  Axis-group reduction surface.  A grid array is classified BY ITS AXIS
#  COORDINATES and reduced per group (grouped reduction over axis coordinates,
#  with no scale-attached axis).  This file holds the value-independent metadata
#  layers; the apply hot path (`[]` type gate + CAGroupIterator + :group
#  reduce driving) is C-level (ext/ca_group_iter.c, ext/carray_access.c).
#
#  The per-axis classifier is CACategorical (carray/categorical.rb): dense
#  integer codes (its storage parent) + a label vocabulary.  A rank-N
#  categorical (an N-D codes map, e.g. a [nlon,nlat] prefecture map) consumes N
#  source axes and collapses them into ONE group axis.  Construction is Ruby
#  (`keys.categorize`); it is not the apply hot path.
#
#  Two metadata layers built here:
#
#    AxisGroup    -- spec built by `value.axis_group(cat_or_nil, ...)`: slot
#                    position = axis, a CACategorical slot is a group axis,
#                    nil = band (held) axis.  The value is a SHAPE TEMPLATE only
#                    (rank + axis lengths), value-independent so one spec serves
#                    many arrays.
#    GroupLabels  -- lazy, factorized label view returned by g.labels.

class CArray

  # ------------------------------------------------------------------------
  #  CArray#axis_group(cat_or_nil, ...) -- build an AxisGroup spec.
  #
  #  Slot position = source axis.  A CACategorical slot consumes cat.ndim source
  #  axes (rank-1 = one axis, rank-N = several axes collapsed into one group
  #  axis); a nil slot is a band (held) axis.  ALL axes must be given
  #  explicitly -- the rank-sum must equal self.ndim, trailing omission / nil
  #  fill is forbidden (explicit > implicit).  The value is used as a
  #  shape TEMPLATE only (its data is never read).
  def axis_group (*slots)
    AxisGroup.new(self, slots)
  end
end

# ----------------------------------------------------------------------------
#  AxisGroup -- value-independent grouping spec.
# ----------------------------------------------------------------------------
class AxisGroup

  # Built from CArray#axis_group.  `value` is the shape template; `slots` is the
  # raw slot list (CACategorical or nil per slot).
  def initialize (value, slots)
    ndim  = value.ndim
    shape = value.shape
    meta  = []
    cursor = 0

    slots.each do |slot|
      case slot
      when nil
        if cursor >= ndim
          raise IndexError,
                "axis_group: too many slots for ndim #{ndim}"
        end
        meta << { kind: :band, axis: cursor, len: shape[cursor] }
        cursor += 1
      when CACategorical
        rank = slot.ndim
        if cursor + rank > ndim
          raise IndexError,
                "axis_group: categorical of rank #{rank} at axis #{cursor} " \
                "exceeds ndim #{ndim}"
        end
        consumed = (cursor...cursor + rank).to_a
        consumed.each_with_index do |a, j|
          if slot.shape[j] != shape[a]
            raise IndexError,
                  "axis_group: categorical axis #{j} length #{slot.shape[j]} " \
                  "!= source axis #{a} length #{shape[a]}"
          end
        end
        meta << { kind: :group, axes: consumed, k: slot.labels.size,
                  codes: slot.codes, labels: slot.labels }
        cursor += rank
      else
        raise TypeError,
              "axis_group: slot must be a CACategorical or nil " \
              "(got #{slot.class})"
      end
    end

    unless cursor == ndim
      raise IndexError,
            "axis_group: slots cover #{cursor} of #{ndim} axes; all axes must " \
            "be given explicitly (no trailing omission / implicit nil fill)"
    end

    @ndim           = ndim
    @template_shape = shape
    @slot_meta      = meta.freeze
    freeze
  end

  attr_reader :ndim, :template_shape

  # Number of output slots (= number of slots in the spec; each slot is one
  # output axis before any band reduction).
  def nslots
    @slot_meta.size
  end

  # @!visibility private
  def slot_meta
    @slot_meta
  end

  # Build the reduction plan for the kernel.  `fused` is the list of band SLOT
  # positions to fold into the statistic (= integer axes given alongside
  # :group).  Returns
  #   [group_axes, bundles, group_dims, perm, squeeze]
  # where
  #   group_axes : ascending source axes handed to the kernel as the slab.
  #   bundles    : [codes, k, consumed_axes] per effective group slot (slot
  #                order); a fused band slot becomes a k=1 all-zero bundle.
  #   group_dims : the effective group dims (slot order) to reshape the leading
  #                K_total axis into.
  #   perm       : permutation mapping the reshaped layout
  #                [*group_dims, *preserved_band_dims] to slot order.
  #   squeeze    : slot positions (slot order) that are length-1 (fused bands)
  #                to drop after the transpose.
  def reduce_plan (fused)
    fused = Array(fused)
    fused.each do |s|
      m = @slot_meta[s]
      unless m && m[:kind] == :band
        raise IndexError,
              "axis_group reduce: axis #{s} is not a band (held) axis; " \
              "use :group to fold group axes"
      end
    end

    eff_group      = []
    preserved_band = []
    @slot_meta.each_with_index do |m, s|
      if m[:kind] == :group || fused.include?(s)
        eff_group << s
      else
        preserved_band << s
      end
    end

    bundles = eff_group.map do |s|
      m = @slot_meta[s]
      if m[:kind] == :group
        [m[:codes], m[:k], m[:axes]]
      else
        [CArray.int32(m[:len]), 1, [m[:axis]]]
      end
    end

    group_axes = eff_group.flat_map { |s|
      m = @slot_meta[s]
      m[:kind] == :group ? m[:axes] : [m[:axis]]
    }.sort

    group_dims = eff_group.map { |s|
      m = @slot_meta[s]
      m[:kind] == :group ? m[:k] : 1
    }

    gp = eff_group.size
    reshaped_axis = {}
    eff_group.each_with_index      { |s, p| reshaped_axis[s] = p }
    preserved_band.each_with_index { |s, q| reshaped_axis[s] = gp + q }
    perm = (0...@slot_meta.size).map { |s| reshaped_axis[s] }

    [group_axes, bundles, group_dims, perm, fused.sort]
  end

  # ------------------------------------------------------------------------
  #  labels -- coordinate labels in the SAME index space as a reduced result.
  #
  #    g.labels(i, j, k)     -> the block's label tuple (Array); group axis =
  #                             its label, band axis = its integer index.
  #    g.labels(axis: SPEC)  -> a GroupLabels view in the index space of
  #                             value[g].reduce(axis: SPEC) (lockstep).
  #    g.labels              -> a GroupLabels view of the full grouped space.
  def labels (*idx, axis: nil)
    unless idx.empty?
      if axis
        raise ArgumentError, "labels: pass either positional index or axis:"
      end
      return full_labels[*idx]
    end
    return full_labels unless axis

    has_group, fused = AxisGroup.parse_axis(axis)
    unless has_group
      raise ArgumentError,
            "labels(axis:) needs :group (labels track the grouped result)"
    end
    survivors = (0...@slot_meta.size).reject { |s| fused.include?(s) }
    GroupLabels.new(survivors.map { |s| axis_vector(s) })
  end

  # Full-space label view (every slot survives, slot order).
  def full_labels
    GroupLabels.new((0...@slot_meta.size).map { |s| axis_vector(s) })
  end

  # Per-slot label vector descriptor for GroupLabels.
  #   group slot -> [:names, labels_array]
  #   band slot  -> [:identity, len]
  def axis_vector (s)
    m = @slot_meta[s]
    if m[:kind] == :group
      [:names, m[:labels]]
    else
      [:identity, m[:len]]
    end
  end

  # Parse an axis: spec into [has_group, fused_band_slot_positions].
  def self.parse_axis (axis)
    has_group = false
    fused = []
    Array(axis).each do |a|
      if a == :group
        has_group = true
      elsif a.is_a?(Integer)
        fused << a
      else
        raise TypeError,
              "axis_group reduce: axis entry must be :group or Integer " \
              "(got #{a.inspect})"
      end
    end
    [has_group, fused]
  end

  # @return [String]
  def inspect
    kinds = @slot_meta.map { |m| m[:kind] == :group ? "g#{m[:k]}" : "band" }
    "#<AxisGroup ndim=#{@ndim} slots=[#{kinds.join(', ')}]>"
  end
end

# ----------------------------------------------------------------------------
#  GroupLabels -- lazy, factorized label view.
#
#  Stores one 1-D label vector per surviving output axis (group axis = its
#  categorical labels; band axis = identity 0...len).  Block label tuples are
#  built on demand from the product -- the N-tuple table is NEVER materialised,
#  so storage is linear in the number of axes, not the block count.
# ----------------------------------------------------------------------------
class GroupLabels

  def initialize (vectors)
    @vectors = vectors          # Array of [:names, array] / [:identity, len]
    @shape   = vectors.map { |kind, data| kind == :names ? data.size : data }
                      .freeze
    freeze
  end

  attr_reader :shape

  # @return [Integer] the number of grouped axes.
  def ndim
    @vectors.size
  end

  # Block label tuple at the given index (length = ndim).
  def [] (*idx)
    if idx.size != @vectors.size
      raise IndexError,
            "GroupLabels: expected #{@vectors.size} indices, got #{idx.size}"
    end
    @vectors.each_with_index.map do |(kind, data), ax|
      i = idx[ax]
      len = (kind == :names) ? data.size : data
      i += len if i < 0
      if i < 0 || i >= len
        raise IndexError, "GroupLabels: index #{idx[ax]} out of range for axis #{ax}"
      end
      (kind == :names) ? data[i] : i
    end
  end

  # The label vector for output axis k (Array): group labels or the identity
  # range of a band axis.
  def axis (k)
    kind, data = @vectors[k]
    (kind == :names) ? data.dup : (0...data).to_a
  end

  # All per-axis label vectors (the table axis headings).
  def coords
    (0...@vectors.size).map { |k| axis(k) }
  end

  # @return [String]
  def inspect
    "#<GroupLabels shape=#{@shape.inspect}>"
  end
end

# Let the C [] type gate (ext/ca_group_iter.c) recognise these classes without
# a kind_of on every index.  Registered once on first load of this file, which
# happens either eagerly (a `axis_group` / AxisGroup call) or lazily from the C
# gate itself the first time it meets a fixlen-surface CArray index (see
# ca_argv_has_group).  CACategorical is the classifier, so it must be defined
# before the register call.
# CAGroupIterator (C-defined in ext/ca_group_iter.c) — the reduction dispatcher
# returned by the `[]` group gate. Its scatterable reductions (sum / prod / mean
# / min / max / variance / stddev / variancep / stddevp / count /
# count_not_masked / all / any) bind in C to one driver; the rest of the common
# iterator surface that composes cheaply from those is added here.
class CAGroupIterator
  # Per-group classified cell count (mask-independent) = count on the
  # mask-stripped value, so every classified cell is counted regardless of the
  # value mask (unlike count / count_not_masked, which count present cells).
  def elements (**kw)
    self.class.__build__(value.value, spec).count(**kw)
  end

  # Per-group count of value-masked cells = elements - count_not_masked.
  def count_masked (**kw)
    elements(**kw) - count_not_masked(**kw)
  end

  # Per-group [min, max] pair (matching CArray#minmax).
  def minmax (**kw)
    [min(**kw), max(**kw)]
  end

  # @overload min_index
  # @overload max_index
  #   Not provided for a group iterator: a group preserves source order, so a
  #   within-group index is weak (the members are not laid out in a private
  #   axis to index into). Use `min_addr` / `max_addr` for the winner's flat
  #   source address, which indexes back into the original array. Raises
  #   NotImplementedError.
  #   @raise [NotImplementedError]
  def min_index (*)
    raise NotImplementedError,
          "CAGroupIterator has no min_index: a group preserves source order, so " \
          "a within-group index is weak; use min_addr for the winner's flat " \
          "source address (it indexes back into the original array)."
  end

  def max_index (*)
    raise NotImplementedError,
          "CAGroupIterator has no max_index: a group preserves source order, so " \
          "a within-group index is weak; use max_addr for the winner's flat " \
          "source address (it indexes back into the original array)."
  end

  # Weighted sum: group-sum of value*weight. `weights` is a per-cell CArray in
  # the source layout (same shape as value); the product carries the combined
  # value|weight mask, so masked cells drop out. Empty group -> 0.0 (identity).
  # No weighted kernel needed -- it is a plain group-sum of a derived array.
  def wsum (weights, **kw)
    self.class.__build__(value * weights, spec).sum(**kw)
  end

  # Weighted mean = Sum(v*w) / Sum(w), both over the combined present-set. The
  # `value*0 + weights` denominator carries the same value|weight mask, so its
  # group-sum is Sum(w) over exactly the cells value*weight used. An empty group
  # (no present pair) is UNDEF (matching CArray#wmean); a present group whose
  # weights sum to zero yields NaN/Inf (core's 0/0).
  def wmean (weights, **kw)
    prod = value * weights
    num  = self.class.__build__(prod, spec).sum(**kw)
    den  = self.class.__build__(value * 0 + weights, spec).sum(**kw)
    cnt  = self.class.__build__(prod, spec).count_not_masked(**kw)
    out  = num / den
    out[cnt.eq(0)] = UNDEF          # no present pair -> masked (empty group)
    out
  end

  # ---- segment scan: within-group running statistics ---------------------
  #
  # The per-element-emit siblings of the scatter reductions. Unlike a reduction
  # (which collapses the group axes), a scan preserves the source shape: each
  # cell holds the running statistic of its group up to and including that cell,
  # in row-major position order along the grouped axes (per band). Excluded /
  # source-masked cells are UNDEF (they join no running total). All five route
  # through the shared scan_op dispatcher, driving the fused C kernel
  # __axis_group_scan__ (ext/ca_axis_group.c) with peak O(k) extra. A scan
  # cannot fold a band into the statistic (that would collapse an axis), so it
  # accepts only axis: :group; without :group each delegates to the value's
  # same-named scan.

  # @overload cumsum(axis: :group)
  #   Per-group inclusive running sum (float64), source-shaped. Without :group
  #   delegates to the plain value cumsum.
  #   @return [CArray]
  def cumsum (**kw)
    scan_op(:cumsum, kw)
  end

  # @overload cumprod(axis: :group)
  #   Per-group inclusive running product (float64), source-shaped. float64 like
  #   cumsum since the product grows. Without :group delegates to value cumprod.
  #   @return [CArray]
  def cumprod (**kw)
    scan_op(:cumprod, kw)
  end

  # @overload cummax(axis: :group)
  #   Per-group inclusive running maximum, source-shaped, in the source data type
  #   (extrema do not grow magnitude, so the data type is preserved). The first
  #   member of a group emits its own value. Without :group delegates to value
  #   cummax.
  #   @return [CArray]
  def cummax (**kw)
    scan_op(:cummax, kw)
  end

  # @overload cummin(axis: :group)
  #   Per-group inclusive running minimum, source-shaped, in the source data type.
  #   Without :group delegates to value cummin.
  #   @return [CArray]
  def cummin (**kw)
    scan_op(:cummin, kw)
  end

  # @overload cumcount(axis: :group)
  #   Per-group 1-based within-group ordinal (int64), source-shaped: the first
  #   member of a group is 1, the next 2, ... (a running count of the group's
  #   members up to and including the cell). Without :group delegates to the
  #   plain value cumcount (also a 1-based cumulative count of present cells).
  #   @return [CArray]
  def cumcount (**kw)
    scan_op(:cumcount, kw)
  end

  # ---- materialize path: order statistics + generic iteration ------------
  #
  # These need every member of a group held together, so (unlike the scatter
  # reductions) they materialize. Every grouping -- one or several group slots,
  # rank-1 or rank-N categoricals, with or without band (held) axes -- routes
  # through one composite categorical over the group block (composite_layout).
  # Two shapes follow from whether band axes are present:
  #
  #   - FLAT (no band axes): the whole value is grouped through the composite
  #     categorical in one pass; a length-K result reshapes to the group-slot k
  #     dims (slot order).
  #   - BAND (band axes present): the group block is materialised one band
  #     position at a time (peak = O(group-block size), never a whole-array
  #     grouped copy), each block's length-K result written into the group-slot
  #     subspace of a slot-order output.
  #
  # Folding a band INTO an order statistic (axis: [:group, k]) gathers a band
  # axis and a group axis into one statistic -- a different operation -- and
  # remains a follow-up.

  # @overload median
  #   Per-group median (float64), any grouping. See {#percentile}.
  #   @return [CArray]
  def median (**kw)
    order_stat(:median, [], kw)
  end

  # @overload percentile(*pers)
  #   Per-group percentile(s) (float64), any grouping.
  #   @return [CArray, Array<CArray>]
  def percentile (*pers, **kw)
    order_stat(:percentile, pers, kw)
  end

  # @overload quantile
  #   Per-group five-number summary `[min, Q1, median, Q3, max]`, any grouping.
  #   @return [Array<CArray>]
  def quantile (**kw)
    order_stat(:quantile, [], kw)
  end

  # @overload sort_addr
  #   Per-group sorted flat source addresses (group-major). Any grouping (single
  #   or composite group slots, rank-1 or rank-N, flat or band-preserving) is
  #   supported; with no :group it is a plain value.sort_addr.
  #   @return [CArray]
  def sort_addr (**kw)
    has_group, _ = AxisGroup.parse_axis(kw[:axis])
    return value.sort_addr unless has_group
    ccat, _kd, gslots, bslots, gaxes = composite_layout
    return value.group_by_category(ccat).sort_addr if bslots.empty?
    composite_band_sort_addr(ccat, gslots, bslots, gaxes)
  end

  # @overload each { |members| ... }
  #   Yields each group's members (a CArray). A flat grouping yields per group
  #   (composite category); a band-preserving grouping yields per (band position,
  #   composite category), band-major then group order. Without a block returns
  #   an Enumerator.
  def each (&block)
    ccat, _kd, gslots, bslots, gaxes = composite_layout
    return value.group_by_category(ccat).each(&block) if bslots.empty?
    return to_enum(:each) unless block
    each_band_block(ccat, gslots, bslots, gaxes) { |_vi, _oi, _co, gi| gi.each(&block) }
    self
  end

  # @overload map(data_type: nil) { |members| ... }
  #   Group-wise element-wise transform back to a source-shaped array. Excluded
  #   cells (in no group) are UNDEF. Any grouping (single or composite, flat or
  #   band-preserving).
  #   @return [CArray]
  def map (data_type: nil, &block)
    raise LocalJumpError, "no block given (yield)" unless block
    ccat, _kd, gslots, bslots, gaxes = composite_layout
    return value.group_by_category(ccat).map(data_type: data_type, &block) if bslots.empty?
    dt  = data_type || value.data_type
    out = CArray.new(dt, value.shape)
    each_band_block(ccat, gslots, bslots, gaxes) do |val_idx, _oi, _co, gi|
      out[*val_idx] = gi.map(data_type: dt, &block)
    end
    out
  end

  # @overload reduce { |members| ... }
  # @overload reduce(init) { |acc, elem| ... }
  #   Custom per-group reduction (dual form). Output shape = slot order (each
  #   group slot -> its k, each band slot -> its length). Any grouping (single or
  #   composite, flat or band-preserving).
  #   @return [CArray]
  def reduce (*args, data_type: nil, &block)
    raise LocalJumpError, "no block given (yield)" unless block
    ccat, kdims, gslots, bslots, gaxes = composite_layout
    if bslots.empty?
      return value.group_by_category(ccat).reduce(*args, data_type: data_type, &block)
                  .reshape(*kdims)
    end
    dt = data_type || CA_OBJECT
    out_shape = spec.slot_meta.map { |m| m[:kind] == :group ? m[:k] : m[:len] }
    out = CArray.new(dt, out_shape)
    each_band_block(ccat, gslots, bslots, gaxes) do |_vi, out_idx, _co, gi|
      out[*out_idx] = gi.reduce(*args, data_type: dt, &block).reshape(*kdims)
    end
    out
  end

  private

  # Build the composite categorical over the group block (the sub-array spanning
  # every group axis). Each group slot -- rank-1 or rank-N -- contributes its
  # per-axis codes; the slot codes are broadcast into the group-block rank (size
  # at the slot's own axes, 1 elsewhere) and combined into one composite code in
  # slot order: code = sum_i code_i * (product of k of later slots). A cell
  # excluded by ANY slot (masked code) is masked in the composite, so it joins no
  # group (the mask propagates through the broadcast arithmetic). Returns
  # [ccat, kdims, group_slots, band_slots, group_axes], where ccat is a rank-1
  # CACategorical over the flattened group block (k = product of the slots' k,
  # synthetic integer labels) and kdims is the per-group-slot k in slot order
  # (the shape a length-K result reshapes to). This is the classification the C
  # scatter kernel computes on the fly, materialised once so the order
  # statistics / iterate / sort_addr can hold each group's members together.
  def composite_layout
    gslots = spec.slot_meta.select { |m| m[:kind] == :group }
    bslots = spec.slot_meta.select { |m| m[:kind] == :band }
    gaxes  = gslots.flat_map { |m| m[:axes] }.sort
    shape  = value.shape
    gb_rank = gaxes.size
    kdims   = gslots.map { |m| m[:k] }
    place   = Array.new(gslots.size, 1)                 # place value per slot
    (gslots.size - 2).downto(0) { |i| place[i] = place[i + 1] * gslots[i + 1][:k] }
    comp = nil
    gslots.each_with_index do |m, i|
      target = Array.new(gb_rank, 1)
      m[:axes].each { |a| target[gaxes.index(a)] = shape[a] }
      term = m[:codes].reshape(*target)
      term = term * place[i] if place[i] != 1
      comp = comp.nil? ? term : comp + term
    end
    gb_size = gaxes.map { |a| shape[a] }.inject(1, :*)
    ccat = CACategorical.from_codes(comp.reshape(gb_size),
                                    CArray.int32(kdims.inject(1, :*)).seq!)
    [ccat, kdims, gslots, bslots, gaxes]
  end

  # Iterate the band positions of a band-preserving grouping. For each band
  # position it yields the group block grouped by the composite categorical,
  # together with two indices: val_idx (source order -- nil across the group
  # axes, the band coordinate at each band axis -- selecting the group block and
  # placing a source-shaped result) and out_idx (slot order -- nil across the
  # group slots, the band coordinate at each band slot -- placing a slot-shaped
  # result), plus the raw band coordinates. Only one group block's grouped copy
  # is alive at a time (peak = O(group-block size); no whole-array grouped copy).
  # Band positions run row-major over the band slots (slot order).
  def each_band_block (ccat, gslots, bslots, gaxes)
    shape  = value.shape
    ndim   = shape.size
    nslots = spec.slot_meta.size
    band_slot_pos = []
    spec.slot_meta.each_with_index { |m, s| band_slot_pos << s if m[:kind] == :band }
    blens = bslots.map { |m| m[:len] }
    blens.inject(1, :*).times do |t|
      coords = Array.new(bslots.size)
      rem = t
      (bslots.size - 1).downto(0) { |j| coords[j] = rem % blens[j]; rem /= blens[j] }
      val_idx = Array.new(ndim)
      gaxes.each { |a| val_idx[a] = nil }
      bslots.each_with_index { |m, j| val_idx[m[:axis]] = coords[j] }
      out_idx = Array.new(nslots)                       # nil across group slots
      band_slot_pos.each_with_index { |s, j| out_idx[s] = coords[j] }
      yield val_idx, out_idx, coords, value[*val_idx].group_by_category(ccat)
    end
  end

  # Dispatch a segment scan (cumsum / cumprod / cummax / cummin / cumcount). No
  # :group -> the value's same-named scan; axis: :group -> per-group running
  # statistic via the fused scan kernel. Folding a band into a scan (axis:
  # [:group, k]) would collapse an axis, so it is rejected (a scan preserves the
  # source shape).
  def scan_op (op, kw)
    has_group, fused = AxisGroup.parse_axis(kw[:axis])
    unless has_group
      unless value.respond_to?(op)
        raise NotImplementedError, "axis_group scan: value has no ##{op}"
      end
      return value.public_send(op)
    end
    unless fused.empty?
      raise ArgumentError,
            "axis_group scan: folding a band into a scan (axis: [:group, k]) " \
            "is not supported; a scan preserves the source shape"
    end
    group_axes, bundles, = spec.reduce_plan([])
    value.__axis_group_scan__(group_axes, bundles, op)
  end

  # Dispatch an order statistic (median / percentile / quantile). No :group ->
  # plain value reduction; :group -> per-group order statistics via the composite
  # materialize. Folding a band into an order statistic (axis: [:group, k])
  # gathers a group axis and a band axis into one statistic, a different
  # operation, and remains a follow-up.
  def order_stat (op, args, kw)
    has_group, fused = AxisGroup.parse_axis(kw[:axis])
    return value.public_send(op, *args) unless has_group
    unless fused.empty?
      raise NotImplementedError,
            "axis_group: folding a band into an order statistic (axis: [:group, k]) " \
            "is not supported; order statistics gather every member of a group"
    end
    composite_order(op, args)
  end

  # Per-group order statistic over the composite grouping. A flat grouping (no
  # band axes) reduces the whole value through the composite categorical and
  # reshapes the length-K result to the group-slot k dims (slot order). A
  # band-preserving grouping runs the per-band-block materialize: output shape =
  # slot order (each group slot -> its k, each band slot -> its length), each
  # band position's length-K result written into the group-slot subspace.
  # quantile emits five outputs. Empty / all-masked groups are UNDEF cells
  # (inherited from the categorical engine).
  def composite_order (op, args)
    ccat, kdims, gslots, bslots, gaxes = composite_layout
    nout = (op == :quantile) ? 5 : 1
    if bslots.empty?
      res = value.group_by_category(ccat).public_send(op, *args)
      return nout == 1 ? res.reshape(*kdims) : res.map { |r| r.reshape(*kdims) }
    end
    out_shape = spec.slot_meta.map { |m| m[:kind] == :group ? m[:k] : m[:len] }
    outs = Array.new(nout) { CArray.float64(*out_shape) }
    each_band_block(ccat, gslots, bslots, gaxes) do |_vi, out_idx, _co, gi|
      result = gi.public_send(op, *args)
      if nout == 1
        outs[0][*out_idx] = result.reshape(*kdims)
      else
        result.each_with_index { |r, q| outs[q][*out_idx] = r.reshape(*kdims) }
      end
    end
    nout == 1 ? outs[0] : outs
  end

  # Per-band-block sorted flat source addresses. Every band position contributes
  # the same nvalid = ccat.category_sizes.sum classified cells (the group
  # classification does not depend on the band position), so the output is a
  # regular length nband*nvalid int64: band positions row-major (slot order),
  # each holding that block's addresses composite-group-major (split by
  # ccat.category_sizes), each group ascending by value. A group-block-local sort
  # address is lifted to the full flat source address by base + sum over the
  # group axes of coord * row-major-stride, base being the band coordinates'
  # contribution; the per-axis ramps are broadcast into the group-block rank.
  # Masked values sort to the tail of their group (as CArray#sort). Peak stays
  # O(group-block size) -- one block's grouped copy at a time.
  def composite_band_sort_addr (ccat, gslots, bslots, gaxes)
    shape   = value.shape
    strides = Array.new(shape.size)
    acc = 1
    (shape.size - 1).downto(0) { |a| strides[a] = acc; acc *= shape[a] }
    gb_rank  = gaxes.size
    gb_shape = gaxes.map { |a| shape[a] }
    gb_size  = gb_shape.inject(1, :*)
    nvalid   = ccat.category_sizes.int64.sum
    nband    = bslots.map { |m| m[:len] }.inject(1, :*)
    out = CArray.int64(nband * nvalid)
    cursor = 0
    each_band_block(ccat, gslots, bslots, gaxes) do |_vi, _oi, coords, gi|
      base = bslots.each_with_index.inject(0) { |s, (m, j)| s + coords[j] * strides[m[:axis]] }
      addr_block = CArray.int64(*gb_shape)
      addr_block[] = base
      gaxes.each_with_index do |a, p|
        target = Array.new(gb_rank, 1)
        target[p] = shape[a]
        addr_block = addr_block + (CArray.int64(shape[a]).seq! * strides[a]).reshape(*target)
      end
      local = gi.sort_addr                              # into the group block
      out[cursor...cursor + nvalid] = addr_block.reshape(gb_size)[local]
      cursor += nvalid
    end
    out
  end
end

require "carray/categorical"
CArray.__register_axis_group_classes__(CACategorical, AxisGroup)

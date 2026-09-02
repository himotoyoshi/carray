# CASlabIterator.
#
# Created by the C indexer dispatch when an index uses the `:>` slab-axis
# sigil (e.g. `ca[nil, :>, :>]`).  It is a thin sugar over each_slab /
# map_slab / reduce_slab: `:>` axes become the slab handed to the block;
# the remaining (sliced) axes are the outer iteration space.
#
#   ca[nil, :>].each { |row| ... }       # = ca.each_slab(axis: 1)
#   ca[2..5, :>, :>].map { |slab| ... }  # = ca[2..5,nil,nil].map_slab(axis: [-2,-1])
#
# Surface is intentionally minimal (each / map / reduce); to_a / count /
# size and other Enumerable extras are deferred.
#
# Naming note: distinct from the C-defined `CArray::SlabIterator` engine
# in ext/carray_slab.c -- this is the Ruby-level sigil iterator that
# delegates to each_slab / map_slab / reduce_slab.  Loaded lazily via
# autoload from lib/carray/autoload/autoload_base.rb on first
# `ca[..., :>]` evaluation.

class CASlabIterator < CAIterator
  # Built from C via `CASlabIterator.new(reference, slab_axes)`: `reference`
  # is the sliced base view (with `:>` axes as full range), `slab_axes` are
  # the positions marked with `:>`.
  def initialize (reference, slab_axes)
    @reference = reference
    @slab_axes = slab_axes
    rdim = reference.shape
    @outer_positions = (0...reference.ndim).reject { |k| slab_axes.include?(k) }.freeze
    @shape             = @outer_positions.map { |k| rdim[k] }
    @ndim            = @shape.size
    self
  end

  # The array being iterated (slab exposes it as `reference`; block / window
  # iterators expose theirs as `source`).  The base has no common accessor.
  attr_reader :reference, :slab_axes

  # Slab view at outer index `idx` (Array, length = self.ndim).  Returns
  # `@reference[*full_idx]` where slab axes are nil (full range) and
  # outer axes take their values from idx.
  def kernel_at_index (idx)
    full = Array.new(@reference.ndim)        # nil at every position
    @outer_positions.each_with_index { |k, i| full[k] = idx[i] }
    @reference[*full]
  end

  # @overload each { |slab| ... }
  #   Yields each slab as an inner CArray. Without a block, returns
  #   an `Enumerator` from `each_slab`.
  #   @yieldparam slab [CArray]
  #   @return [Enumerator, self]
  def each (&block)
    return @reference.each_slab(axis: @slab_axes) unless block
    @reference.each_slab(axis: @slab_axes, &block)
  end

  # @overload map { |slab| ... }
  #   Returns a new CArray built by applying the block to each slab,
  #   delegating to `map_slab`.
  #   @yieldparam slab [CArray]
  #   @yieldreturn [Object] per-slab result.
  #   @return [CArray]
  def map (&block)
    @reference.map_slab(axis: @slab_axes, &block)
  end

  # @overload reduce { |acc, slab| ... }
  #   Reduces the slabs with `reduce_slab`. The block-only form uses
  #   the first slab as the seed; the `init` form starts from `init`.
  #   @yieldparam acc [Object] running accumulator.
  #   @yieldparam slab [CArray] next slab.
  #   @yieldreturn [Object] updated accumulator.
  #   @return [Object]
  # @overload reduce(init) { |acc, slab| ... }
  #   @param init [Object] initial accumulator value.
  #   @yieldparam acc [Object]
  #   @yieldparam slab [CArray]
  #   @yieldreturn [Object]
  #   @return [Object]
  def reduce (*args, &block)
    if args.empty?
      @reference.reduce_slab(axis: @slab_axes, &block)
    else
      @reference.reduce_slab(axis: @slab_axes, init: args[0], &block)
    end
  end

  # ---- named reductions -------------------------------------------------
  #
  # A per-slab reduction that folds each slab to one value is exactly the core
  # per-axis reduction over the slab axes, so every reduction is a direct
  # delegation to `reference.<op>(axis: slab_axes)`. This inherits the core
  # data type, mask, empty/all-masked (identity vs UNDEF) and epsilon-close
  # contracts unchanged -- there is no separate slab reduction kernel. (Unlike
  # the map / reduce block surface, these are mask-aware: they route through the
  # core reduction, which handles masked sources.)

  # @overload sum
  #   Per-slab sum, delegating to `reference.sum(axis: slab_axes)`.
  #   @return [CArray] one value per slab (shape = self.dim minus the slab axes)
  # @overload accumulate
  #   Per-slab sum kept in the source's own data type, wrapping at its width,
  #   as the core `accumulate` does -- `sum` answers in the type the core
  #   promotes to (float64 for integers).
  #   @return [CArray] one value per slab
  # The rest are analogous: prod / mean / min / max, sample and population
  # variance / stddev, all / any, fused minmax ([min, max] pair), the axis-local
  # position min_index / max_index (index within the slab axes), and the flat
  # source address min_addr / max_addr (which source cell holds the extremum).
  [:sum, :accumulate, :prod, :mean, :min, :max, :variance, :stddev, :all, :any,
   :variancep, :stddevp, :minmax, :min_index, :max_index,
   :min_addr, :max_addr].each do |op|
    class_eval <<~RUBY, __FILE__, __LINE__ + 1
      def #{op}
        @reference.#{op}(axis: @slab_axes)
      end
    RUBY
  end

  # @overload count(v = <none>)
  #   Per-slab count, delegating to `reference.count(..., axis: slab_axes)`.
  #   No argument counts present (non-masked) cells; `count(UNDEF)` counts
  #   masked cells; `count(v)` counts cells equal to `v`.
  #   @return [CArray] one count per slab
  def count (*args)
    return count_not_masked if args.empty?
    # CABlock / CAWindow shadow #count with a geometry accessor, and @reference
    # may be such a view, so dispatch CArray#count explicitly for count(v).
    CArray.instance_method(:count).bind_call(@reference, *args, axis: @slab_axes)
  end

  # @overload count_not_masked
  #   Per-slab count of present (non-masked) cells.
  #   @return [CArray]
  def count_not_masked
    @reference.count_not_masked(axis: @slab_axes)
  end

  # @overload count_masked
  #   Per-slab count of masked cells.
  #   @return [CArray]
  def count_masked
    @reference.count_masked(axis: @slab_axes)
  end

  # @overload elements
  #   Per-slab cell count (structural, mask-independent). Every slab has the
  #   same shape, so this is a constant array shaped like the outer iteration
  #   space.
  #   @return [CArray]
  def elements
    sz  = @slab_axes.inject(1) { |p, ax| p * @reference.shape[ax] }
    # count_not_masked gives the correct output shape (and, unlike bare #count,
    # is not shadowed by CABlock / CAWindow); overwrite with the constant size.
    out = @reference.count_not_masked(axis: @slab_axes)
    out[] = sz
    out
  end

  # ---- order statistics (tier 3) ----------------------------------------
  #
  # Core order statistics take a single integer axis, so a single slab axis is
  # delegated directly (fast C path) and a multi-axis slab is folded per slab
  # with reduce_slab (each slab flattened). As with `CArray#median(axis:)`, a
  # masked source raises (the known per-axis masked limitation); strip the mask
  # with `ca.value` first if needed.

  # @overload median
  #   Per-slab median.
  #   @return [CArray]
  def median
    if @slab_axes.size == 1
      @reference.median(axis: @slab_axes[0])
    else
      @reference.reduce_slab(axis: @slab_axes) { |s| s.median }
    end
  end

  # @overload percentile(*pers)
  #   Per-slab percentile(s). One argument returns one CArray; several return an
  #   array of CArrays (as `CArray#percentile`).
  #   @return [CArray, Array<CArray>]
  def percentile (*pers)
    if @slab_axes.size == 1
      @reference.percentile(*pers, axis: @slab_axes[0])
    else
      rs = pers.map { |p| @reference.reduce_slab(axis: @slab_axes) { |s| s.percentile(p) } }
      pers.size == 1 ? rs[0] : rs
    end
  end

  # @overload quantile
  #   Per-slab five-number summary `[min, Q1, median, Q3, max]` (five CArrays),
  #   as `CArray#quantile`.
  #   @return [Array<CArray>]
  def quantile
    if @slab_axes.size == 1
      @reference.quantile(axis: @slab_axes[0])
    else
      [0, 25, 50, 75, 100].map { |p|
        @reference.reduce_slab(axis: @slab_axes) { |s| s.percentile(p) }
      }
    end
  end

  # ---- order surface ----------------------------------------------------
  #
  # sort_addr / sort_index lift the core order surface per slab. Core sort takes
  # a single axis, so a one-axis slab delegates straight to the C path (unlike
  # the reductions above, sort does not accept an axis array). A multi-axis slab
  # has no single sort axis, so it raises; sort one axis at a time.

  # @overload sort_addr
  #   Per-slab sort by flat source address. Delegates to
  #   `reference.sort_addr(axis: slab_axis)`: reference-shaped, each slab's cells
  #   carry the flat source addresses that sort that slab ascending.
  #   @return [CArray] reference-shaped int64
  def sort_addr
    @reference.sort_addr(axis: single_sort_axis(:sort_addr))
  end

  # @overload sort_index
  #   Per-slab sort by axis-local index (usable with take_along_axis).
  #   Delegates to `reference.sort_index(axis: slab_axis)`: reference-shaped, the
  #   axis-local rank order within the slab axis.
  #   @return [CArray] reference-shaped int64
  def sort_index
    @reference.sort_index(axis: single_sort_axis(:sort_index))
  end

  # ---- weighted (tier 2) ------------------------------------------------
  #
  # Delegated to the core weighted reduction over the slab axes; `weights` has
  # the same shape as the reference (one weight per cell). Core wsum / wmean
  # accept multi-axis, so this covers multi-axis slabs directly.

  # @overload wsum(weights)
  #   Per-slab weighted sum, `weights` shaped like the reference.
  #   @return [CArray]
  def wsum (weights)
    @reference.wsum(weights, axis: @slab_axes)
  end

  # @overload wmean(weights)
  #   Per-slab weighted mean, `weights` shaped like the reference.
  #   @return [CArray]
  def wmean (weights)
    @reference.wmean(weights, axis: @slab_axes)
  end

  # ---- segment scan: within-slab running statistics ---------------------
  #
  # A per-slab running accumulation along the slab axis is exactly the core
  # per-axis cumulative over that axis, so every scan delegates to
  # `reference.<op>(axis: slab_axis)`, inheriting the core data type / mask (masked
  # cells hold the running total, output unmasked) contracts unchanged. Each
  # cell is in exactly one slab (a partition), so the running value is
  # well-defined; the surface is uniform with the family even though it
  # coincides with a plain per-axis cumulative. Core scan takes a single axis (a
  # multi-axis running accumulation is ambiguous), so a multi-axis slab raises --
  # scan one axis at a time, like the order surface.

  # @overload cumsum
  #   Per-slab inclusive running sum (float64), reference-shaped.
  #   @return [CArray]
  # @overload cumprod
  #   Per-slab inclusive running product (float64), reference-shaped.
  #   @return [CArray]
  # @overload cummax
  #   Per-slab inclusive running maximum (reference data type), reference-shaped.
  #   @return [CArray]
  # @overload cummin
  #   Per-slab inclusive running minimum (reference data type), reference-shaped.
  #   @return [CArray]
  # @overload cumcount
  #   Per-slab running count of present cells (int64), reference-shaped.
  #   @return [CArray]
  [:cumsum, :cumprod, :cummax, :cummin, :cumcount].each do |op|
    class_eval <<~RUBY, __FILE__, __LINE__ + 1
      def #{op}
        @reference.#{op}(axis: single_scan_axis(:#{op}))
      end
    RUBY
  end

  private

  # The single slab axis for the order surface (core sort takes one integer
  # axis). A multi-axis slab has no single sort axis, so raise.
  def single_sort_axis (op)
    return @slab_axes[0] if @slab_axes.size == 1
    raise ArgumentError,
          "#{op}: a multi-axis slab (axes #{@slab_axes.inspect}) has no single " \
          "sort axis; sort one axis at a time"
  end

  # The single slab axis for a segment scan (core scan takes one integer axis).
  # A multi-axis slab has no single scan axis, so raise.
  def single_scan_axis (op)
    return @slab_axes[0] if @slab_axes.size == 1
    raise ArgumentError,
          "#{op}: a multi-axis slab (axes #{@slab_axes.inspect}) has no single " \
          "scan axis; scan one axis at a time"
  end
end

# ----------------------------------------------------------------------------
#
#  carray/block_iterator.rb
#
#  CABlockIterator — a non-overlapping tile reduction dispatcher, the Block
#  member of the 3.0 iterator family (sibling of CASlabIterator /
#  CAWindowIterator / CACategoricalIterator).  Where a window iterator folds an
#  overlapping window per anchor, a block iterator folds each non-overlapping
#  tile of a fixed per-axis size, so the output is a tile grid (pooling /
#  block statistics / downsampling).
#
#      bi = a.blocks(3, 3)            # 3x3 non-overlapping tiles
#      bi.mean                        # per-tile mean (average pooling)
#      bi.max                         # per-tile max (max pooling)
#
#  Engine: block_view decomposition.  The source splits into an interior region
#  (all axes on a size-divisible extent) plus 2^m - 1 boundary regions (m = the
#  number of axes whose length is not a multiple of the tile size).  Each region
#  is a `block_view` (a CAStride: zero-copy over the source via compose-fold),
#  reduced over the trailing tile axes by a core reduction and scattered into the
#  ceil-shaped tile grid.  One core reduction per region; the named reductions
#  delegate straight to the core, so their data type / mask / empty (ERI) / epsilon
#  contracts are the core's, unchanged.  Because tiles do not overlap, no
#  padded entity is built (unlike CAWindowIterator) and the interior stays on
#  the source buffer.
#
#  The remainder is not the user's concern.  There is no boundary-policy knob:
#  the sole behaviour is full coverage — every cell belongs to a tile, the
#  edge tiles simply fold whatever cells are present (present-only), and the
#  output is the ceil tile grid.  A partial edge tile carries fewer real cells,
#  so a core `min_count:` naturally marks it UNDEF when it is not full.  "Valid"
#  pooling (drop the remainder, floor grid) is expressed explicitly by slicing
#  first: `a[0...q*b].blocks(b)`.
#
#  The class name is kept from 2.0 (the concept — a tile — is stable);
#  this is the Ruby family member that supersedes the retired C engine
#  (ext/ca_iter_block.c).  Loaded lazily via
#  autoload from lib/carray/autoload_carray.rb the first time `a.blocks(...)`
#  is used.
#
# ----------------------------------------------------------------------------

require "carray"

# Non-overlapping tile reduction dispatcher — the Block member of the
# iterator family (sibling of `CASlabIterator` / {CAWindowIterator} /
# `CACategoricalIterator`).  Where a window iterator folds an overlapping
# window per anchor, a block iterator folds each non-overlapping tile of a
# fixed per-axis size, so the result is a tile grid: pooling, downsampling,
# block statistics.
#
# Obtained from `CArray#blocks`, not constructed directly.
#
# @example
#   bi = a.blocks(3, 3)   # 3x3 non-overlapping tiles
#   bi.mean               # per-tile mean (average pooling)
#   bi.max                # per-tile max (max pooling)
class CABlockIterator < CAIterator

  # @overload initialize(source, *blocks)
  #   Builds a block iterator tiling `source` with a per-axis tile size.  Each
  #   `blocks[i]` is either an Integer tile size (offset 0) or a `lo..hi` range
  #   whose length is the tile size and whose start is a leading offset
  #   (backward compatible with the 2.0 `a.blocks(2..4)` form).  A single Array
  #   argument is taken as the per-axis size list.
  #
  #   @param source [CArray] the array to tile.
  #   @param blocks [Array<Integer, Range>] per-axis tile sizes (or ranges).
  def initialize (source, *blocks)
    blocks = blocks[0] if blocks.size == 1 && blocks[0].is_a?(Array)

    unless blocks.size == source.ndim
      raise ArgumentError,
            "blocks: expected #{source.ndim} tile sizes (one per axis), " \
            "got #{blocks.size}"
    end

    @sndim   = source.ndim
    offsets  = Array.new(@sndim, 0)
    @sizes   = Array.new(@sndim)
    blocks.each_with_index do |b, i|
      if b.is_a?(Range)
        offsets[i] = b.begin
        @sizes[i]  = b.end - b.begin + (b.exclude_end? ? 0 : 1)
      else
        @sizes[i]  = Integer(b)
      end
      if @sizes[i] < 1
        raise ArgumentError, "blocks: tile size on axis #{i} must be >= 1"
      end
    end

    # Absorb a leading offset with a zero-copy pre-slice, so the tile geometry
    # below always starts at index 0.
    @source =
      if offsets.all?(&:zero?)
        source
      else
        source[*offsets.map { |o| o..-1 }]
      end

    n     = @source.shape
    @q    = @sndim.times.map { |i| n[i] / @sizes[i] }   # full tiles per axis
    @r    = @sndim.times.map { |i| n[i] % @sizes[i] }   # remainder per axis

    # Ceil tile grid: a partial edge tile adds one grid cell on that axis.
    @shape  = @sndim.times.map { |i| @q[i] + (@r[i] > 0 ? 1 : 0) }
    @ndim = @shape.size

    # Trailing tile axes of a block_view: [ndim .. 2*ndim-1].
    @tile_axes = (@sndim...(2 * @sndim)).to_a
    self
  end

  # @overload source
  #   Returns the array being tiled (with any leading offset already applied).
  #   @return [CArray]
  attr_reader :source

  # ---- region decomposition ---------------------------------------------
  #
  # The tile grid splits into regions by whether each axis sits on its interior
  # (full tiles, extent q_i) or its boundary (the one partial edge tile).  A
  # region is the Cartesian product of these per-axis choices; the all-interior
  # choice is the interior region, the rest are the 2^m - 1 boundary regions.
  # Each region is a plain block_view whose tile size on an axis is the full
  # size (interior) or the remainder (boundary) — always dividing the region's
  # extent, so block_view never rejects.

  private

  # Yield each region as (strip_ranges, tiles, out_ranges): the source slice to
  # tile, the per-axis tile sizes, and the sub-block of the output grid it fills.
  def each_region
    axis_choices = (0...@sndim).map do |i|
      ch = []
      ch << :interior if @q[i] > 0
      ch << :boundary if @r[i] > 0
      ch
    end
    combos = axis_choices[0].product(*axis_choices[1..-1])
    combos.each do |choice|
      strip_ranges = []
      tiles        = []
      out_ranges   = []
      (0...@sndim).each do |i|
        base = @q[i] * @sizes[i]
        if choice[i] == :interior
          strip_ranges << (0...base)
          tiles        << @sizes[i]
          out_ranges   << (0...@q[i])
        else
          strip_ranges << (base...(base + @r[i]))
          tiles        << @r[i]
          out_ranges   << (@q[i]...(@q[i] + 1))
        end
      end
      yield strip_ranges, tiles, out_ranges
    end
  end

  # Reduce every region with the yielded block (a block_view over the region
  # and its tile sizes) and scatter the region results into the ceil tile grid.
  # The block returns one CArray, or an Array of CArrays (minmax / percentile /
  # quantile) which are assembled into that many grids.  Boundary regions use a
  # smaller (unmasked, ragged) block_view whose present cell count is naturally
  # below a full tile, so `min_count:` marks them UNDEF with no masking.  The
  # output data type is seeded from the first region (all regions share it).
  def assemble
    outs = nil
    each_region do |strip_ranges, tiles, out_ranges|
      view = @source[*strip_ranges].block_view(*tiles)
      res  = yield(view, tiles)
      if res.is_a?(Array)
        outs ||= res.map { |r| CArray.new(r.data_type, @shape) }
        res.each_index { |k| outs[k][*out_ranges] = res[k] }
      else
        outs ||= CArray.new(res.data_type, @shape)
        outs[*out_ranges] = res
      end
    end
    outs
  end

  # Fold every region with a single core reduction `op` (the tier-1 shape).
  def fold (op, **kw)
    assemble { |view, _tiles| view.send(op, axis: @tile_axes, **kw) }
  end

  public

  # ---- named reductions (core delegation, drift zero) -------------------
  #
  # A per-tile fold to one value over the trailing tile axes is exactly a core
  # per-axis reduction over those axes, so every reduction delegates to
  # `block_view.<op>(axis: tile_axes, ...)` per region.  This inherits the core
  # data type, mask, empty / all-masked (identity vs UNDEF) and epsilon-close
  # contracts unchanged.  `min_count:` / `fill_value:` pass straight to the core.

  # @overload sum(min_count: nil, fill_value: nil)
  #   Per-tile sum.  @return [CArray] tile-grid shaped
  # The rest are analogous: prod / mean / min / max, sample and population
  # variance / stddev, all / any.
  [:sum, :prod, :mean, :min, :max, :variance, :stddev, :all, :any,
   :variancep, :stddevp].each do |op|
    define_method(op) do |min_count: nil, fill_value: nil|
      kw = {}
      kw[:min_count]  = min_count  unless min_count.nil?
      kw[:fill_value] = fill_value unless fill_value.nil?
      fold(op, **kw)
    end
  end

  # ---- count family and elements ----------------------------------------

  # @overload count(v = <none>)
  #   Per-tile count.  No argument counts present (non-masked) cells (fewer at a
  #   partial edge tile); `count(UNDEF)` counts masked cells; `count(v)` counts
  #   cells equal to `v`.
  #   @return [CArray] tile-grid shaped
  def count (*args)
    return count_not_masked if args.empty?
    out = nil
    each_region do |strip_ranges, tiles, out_ranges|
      view = @source[*strip_ranges].block_view(*tiles)
      # block_view is a CAStride, so #count is not shadowed; dispatch
      # CArray#count explicitly anyway, matching the family regularity.
      red = CArray.instance_method(:count).bind_call(view, *args, axis: @tile_axes)
      out ||= CArray.new(red.data_type, @shape)
      out[*out_ranges] = red
    end
    out
  end

  # @overload count_not_masked
  #   Per-tile count of present (non-masked) cells.  For a partial edge tile
  #   this is the real cell count (the OOB cells are not present).
  #   @return [CArray]
  def count_not_masked
    fold(:count_not_masked)
  end

  # @overload count_masked
  #   Per-tile count of masked cells.  Equals `elements - count_not_masked`;
  #   the OOB cells of a partial edge tile count here.
  #   @return [CArray]
  def count_masked
    elements - count_not_masked
  end

  # @overload elements
  #   Tile cell count (structural, mask-independent): the constant tile size
  #   `Π b_i`, shaped like the tile grid.  Every tile — including a partial
  #   edge tile — reports the full size; how many of those cells are real is
  #   `count_not_masked`, and `elements = count_not_masked + count_masked`.
  #   @return [CArray]
  def elements
    sz  = @sizes.inject(1) { |p, b| p * b }
    out = CArray.int64(*@shape)
    out[] = sz
    out
  end

  # ---- tier 2: minmax, position, weighted -------------------------------

  # @overload minmax(min_count: nil, fill_value: nil)
  #   Per-tile `[min, max]` (two tile-grid-shaped CArrays, a single fused pass).
  #   @return [Array<CArray>]
  def minmax (min_count: nil, fill_value: nil)
    kw = {}
    kw[:min_count]  = min_count  unless min_count.nil?
    kw[:fill_value] = fill_value unless fill_value.nil?
    assemble { |view, _| view.minmax(axis: @tile_axes, **kw) }
  end

  # @overload min_index
  #   Per-tile position of the minimum, as a flat index within the tile (a
  #   partial edge tile indexes within its own present cells).
  #   @return [CArray] tile-grid shaped
  # @overload max_index
  #   Per-tile position of the maximum (tile-local flat index).
  #   @return [CArray]
  [:min_index, :max_index].each do |op|
    define_method(op) { assemble { |view, _| view.send(op, axis: @tile_axes) } }
  end

  # @overload min_addr
  #   Per-tile flat SOURCE address of the minimum — which cell of the source
  #   holds it, so `source.reshape(source.elements)[bi.min_addr]` are the tile
  #   minima. Unlike `min_index` (the tile-local position) this indexes back
  #   into the original array. An all-masked tile is a masked cell.
  #   @return [CArray] tile-grid shaped int64
  def min_addr; winner_addr(:min_index); end

  # @overload max_addr
  #   Per-tile flat source address of the maximum. See {#min_addr}.
  #   @return [CArray] tile-grid shaped int64
  def max_addr; winner_addr(:max_index); end

  private

  # Per-tile source address of the winner. The tile-local flat index (min_index /
  # max_index) is looked up in a source-address companion tiled the same way, so
  # the tile geometry is reused rather than recomputed. An all-masked tile yields
  # a masked index; it is gathered at 0 and re-masked in the result.
  def winner_addr (idx_op)
    saddr = CArray.int64(*@source.shape).seq!
    out = nil
    each_region do |strip_ranges, tiles, out_ranges|
      vview = @source[*strip_ranges].block_view(*tiles)
      sview = saddr[*strip_ranges].block_view(*tiles)
      mi    = vview.send(idx_op, axis: @tile_axes)         # tile-local flat index
      grid  = (0...@sndim).map { |i| vview.shape[i] }
      cells = tiles.inject(1) { |p, t| p * t }
      safe  = mi.copy
      safe[mi.is_masked.eq(1)] = 0 if mi.has_mask?         # placeholder for the gather
      picked = sview.reshape(*(grid + [cells]))
                    .take_along_axis(safe.reshape(*(grid + [1])), axis: @sndim)
                    .reshape(*grid)
      picked[mi.is_masked.eq(1)] = UNDEF if mi.has_mask?   # re-mask the empty tiles
      out ||= CArray.int64(*@shape)
      out[*out_ranges] = picked
    end
    out
  end

  public

  # @overload sort_addr
  #   Per-tile sort by flat SOURCE address, source-shaped: each tile's cells hold
  #   that tile's source addresses in ascending-value order (reading the tile
  #   row-major gives the sorted addresses), so
  #   `source.reshape(source.elements)[bi.sort_addr]` is the source sorted within
  #   each tile. Multi-axis tiles are flattened (as for the order statistics). A
  #   partial edge tile sorts only its present cells. Masked values sort to the
  #   tail of their tile (as `CArray#sort`).
  #   @return [CArray] source-shaped int64
  def sort_addr
    saddr = CArray.int64(*@source.shape).seq!
    out = CArray.int64(*@source.shape)
    out[] = UNDEF
    each_region do |strip_ranges, tiles, _out_ranges|
      vview = @source[*strip_ranges].block_view(*tiles)
      sview = saddr[*strip_ranges].block_view(*tiles)
      grid  = (0...@sndim).map { |i| vview.shape[i] }
      cells = tiles.inject(1) { |p, t| p * t }
      order = vview.copy.reshape(*(grid + [cells])).sort_addr(axis: @sndim)
      src_sorted = sview.reshape(*(grid + [cells])).take_along_axis(order, axis: @sndim)
      out[*strip_ranges].block_view(*tiles)[] = src_sorted.reshape(*(grid + tiles))
    end
    out
  end

  # @overload wsum(weights)
  #   Per-tile weighted sum; `weights` is shaped like one full tile (`Π b_i`).
  #   At a partial edge tile the weight kernel is sliced to the present cells.
  #   @return [CArray]
  def wsum (weights)
    weighted(weights) { |view, w| view.wsum(w, axis: @tile_axes) }
  end

  # @overload wmean(weights)
  #   Per-tile weighted mean; `weights` shaped like one full tile.
  #   @return [CArray]
  def wmean (weights)
    weighted(weights) { |view, w| view.wmean(w, axis: @tile_axes) }
  end

  private

  # Broadcast a full-tile weight kernel over each region (sliced to the region's
  # possibly-ragged tile) and yield (view, broadcast weights) for the reduction.
  def weighted (weights)
    unless weights.shape == @sizes
      raise ArgumentError,
            "wsum/wmean: weights shape #{weights.shape.inspect} != " \
            "tile shape #{@sizes.inspect}"
    end
    assemble do |view, tiles|
      wt     = tiles == @sizes ? weights : weights[*tiles.map { |t| 0...t }]
      wshape = ([1] * @sndim) + tiles
      # Pass the weights through unchanged, like the window iterator: core wsum /
      # wmean own weight / type coercion, so do not pre-coerce the weights here.
      wfull  = wt.reshape(*wshape).broadcast_to(*view.shape)
      yield view, wfull
    end
  end

  public

  # ---- tier 3: order statistics (median / percentile / quantile) --------
  #
  # Core per-axis order statistics take a single integer axis, so a 1-D tile
  # delegates straight to the C path; a multi-axis tile is materialized per
  # region and its tile axes flattened into one before the single-axis core
  # order-stat.  A masked source raises (the known per-axis masked limitation);
  # strip the mask with `ca.value` first if needed.

  # @overload median
  #   Per-tile median.  @return [CArray]
  def median
    order_stat { |v, axis| v.median(axis: axis) }
  end

  # @overload percentile(*pers)
  #   Per-tile percentile(s).  One argument returns one CArray, several an array
  #   of CArrays (as `CArray#percentile`).
  #   @return [CArray, Array<CArray>]
  def percentile (*pers)
    order_stat { |v, axis| v.percentile(*pers, axis: axis) }
  end

  # @overload quantile
  #   Per-tile five-number summary `[min, Q1, median, Q3, max]` (five CArrays).
  #   @return [Array<CArray>]
  def quantile
    order_stat { |v, axis| v.quantile(axis: axis) }
  end

  private

  # Drive an order statistic (yielded as `block.call(view, axis)`) per region:
  # a 1-D tile passes the tile axis straight through; a multi-axis tile is
  # materialized (peak O(region cells)) and its tile axes flattened into one.
  def order_stat (&op)
    assemble do |view, tiles|
      if @sndim == 1
        op.call(view, @tile_axes[0])
      else
        grid  = (0...@sndim).map { |i| view.shape[i] }
        cells = tiles.inject(1) { |p, t| p * t }
        op.call(view.copy.reshape(*(grid + [cells])), @sndim)
      end
    end
  end

  public

  # ---- generic iteration (escape hatch, slow) ---------------------------
  #
  # `each` / `reduce` yield each tile as a uniform `Π b_i`-shaped CArray whose
  # out-of-bounds cells (at a partial edge tile) are masked, so the user never
  # sees a ragged shape — the remainder is absorbed into the mask.  This uses a
  # padded (masked-margin) entity, materialised once, so it is the slow path;
  # named reductions above stay on the zero-copy region engine.  `each` is the
  # receptacle for statistics not in the named surface.

  # @overload each { |tile| ... }
  #   Yields each tile as a uniform `Π b_i`-shaped CArray (partial edge tiles
  #   have their out-of-bounds cells masked).  Without a block, returns an
  #   Enumerator.  Per-tile materialize, slow; use a named reduction for speed.
  #   @yieldparam tile [CArray]
  #   @return [Enumerator, self]
  def each
    return to_enum(:each) unless block_given?
    tgv  = tile_grid_view
    nils = Array.new(@sndim, nil)
    CArray.each_index(*@shape) { |*g| yield tgv[*g, *nils] }
    self
  end

  # @overload reduce { |tile| ... }
  #   Custom per-tile reduction: the block receives each tile (a CArray, masked
  #   at partial edges) and returns one value per tile.  The escape hatch for
  #   statistics not in the named surface.
  #   @yieldparam tile [CArray]
  #   @return [CArray] tile-grid shaped
  # @overload reduce(init) { |acc, elem| ... }
  #   Per-tile fiber fold: each tile's cells are folded element by element from
  #   `init` (masked cells are skipped by CArray#each).
  #   @param init [Object] initial accumulator.
  #   @return [CArray]
  def reduce (*args, data_type: nil, &blk)
    raise LocalJumpError, "no block given (yield)" unless blk
    out  = CArray.new(data_type || CA_OBJECT, @shape)
    tgv  = tile_grid_view
    nils = Array.new(@sndim, nil)
    if args.empty?
      CArray.each_index(*@shape) { |*g| out[*g] = blk.call(tgv[*g, *nils]) }
    else
      init = args[0]
      CArray.each_index(*@shape) do |*g|
        acc = init
        tgv[*g, *nils].each { |e| acc = blk.call(acc, e) }
        out[*g] = acc
      end
    end
    out
  end

  # @overload map { |tile| ... }
  #   Per-tile element-wise transform: the block receives each tile (a uniform
  #   `Π b_i`-shaped CArray, masked at partial edges) and returns a same-shaped
  #   tile (or a scalar to broadcast).  The transformed tiles are scattered back
  #   into a source-shaped CArray (the out-of-bounds cells of a partial edge
  #   tile are dropped).  Well-defined because tiles do not overlap; the source
  #   is not modified (a new array is returned).  Without a block, an Enumerator.
  #   @yieldparam tile [CArray]
  #   @return [CArray, Enumerator] source-shaped
  def map
    return to_enum(:map) unless block_given?
    pout = CArray.new(padded_source.data_type, padded_source.shape)
    pgv  = pout.block_view(*@sizes)
    tgv  = tile_grid_view
    nils = Array.new(@sndim, nil)
    CArray.each_index(*@shape) { |*g| pgv[*g, *nils] = yield(tgv[*g, *nils]) }
    pout[*@sndim.times.map { |i| 0...@source.shape[i] }].copy
  end

  # ---- segment scan: within-tile running statistics ---------------------
  #
  # A tile is a partition (each cell is in exactly one tile), so a per-cell
  # running statistic is well-defined: each tile accumulates in its internal
  # row-major order.  Each tile is flattened (row-major), scanned by the core
  # value scan, reshaped back, and scattered into a source-shaped result --
  # reusing the same padded (masked-margin) entity as the iterate escape
  # hatches, so this is the slow path (a per-tile materialize), and the
  # out-of-bounds cells of a partial edge tile are dropped from the result.
  # cumsum / cumprod -> float64, cummax / cummin preserve the value data type,
  # cumcount -> int64 running count of present cells; the output data type is seeded
  # from the first tile's scan.

  # @overload cumsum
  #   Per-tile inclusive running sum (float64), source-shaped.
  #   @return [CArray]
  # @overload cumprod
  #   Per-tile inclusive running product (float64), source-shaped.
  #   @return [CArray]
  # @overload cummax
  #   Per-tile inclusive running maximum (value data type), source-shaped.
  #   @return [CArray]
  # @overload cummin
  #   Per-tile inclusive running minimum (value data type), source-shaped.
  #   @return [CArray]
  # @overload cumcount
  #   Per-tile running count of present cells (int64), source-shaped.
  #   @return [CArray]
  [:cumsum, :cumprod, :cummax, :cummin, :cumcount].each do |op|
    define_method(op) { block_scan(op) }
  end

  private

  # Drive a within-tile segment scan: scan each tile flattened row-major and
  # scatter back to a source-shaped result.  The output data type is taken from the
  # first tile's scan (all tiles share it); the padded margin is UNDEF and the
  # OOB cells of a partial edge tile are cropped from the result.
  def block_scan (op)
    tgv  = tile_grid_view
    nils = Array.new(@sndim, nil)
    pout = nil
    pgv  = nil
    CArray.each_index(*@shape) do |*g|
      tile    = tgv[*g, *nils]
      scanned = tile.copy.reshape(tile.elements).send(op).reshape(*@sizes)
      unless pout
        pout = CArray.new(scanned.data_type, padded_source.shape)
        pout[] = UNDEF
        pgv  = pout.block_view(*@sizes)
      end
      pgv[*g, *nils] = scanned
    end
    pout[*@sndim.times.map { |i| 0...@source.shape[i] }].copy
  end

  # A padded entity whose interior holds the source and whose partial-edge
  # margin is masked (UNDEF), sized to exactly cover the ceil tile grid.  When
  # the source already divides evenly this is the source itself (no copy), so
  # the tiles alias it.  Memoised; feeds the iterate escape hatches.
  def padded_source
    @padded_source ||= begin
      pshape = @sndim.times.map { |i| @shape[i] * @sizes[i] }
      if pshape == @source.shape.to_a
        @source
      else
        pad = CArray.new(@source.data_type, pshape)
        pad[] = UNDEF
        pad[*@sndim.times.map { |i| 0...@source.shape[i] }] = @source
        pad
      end
    end
  end

  # block_view of the padded entity: shape [g_0..g_{n-1}, b_0..b_{n-1}], so
  # `view[*grid_index, *nils]` is one uniform tile.
  def tile_grid_view
    @tile_grid_view ||= padded_source.block_view(*@sizes)
  end
end


class CArray
  # @overload blocks(*blocks)
  #   Returns a {CABlockIterator} tiling `self` with non-overlapping tiles of a
  #   per-axis size.  Each argument is an Integer tile size (offset 0) or a
  #   `lo..hi` range (length = tile size, start = leading offset).  The
  #   remainder is covered by present-only edge tiles (ceil tile grid); slice
  #   first for "valid" tiling.
  #   @param blocks [Array<Integer, Range>] per-axis tile sizes (or ranges).
  #   @return [CABlockIterator]
  def blocks (*blocks)
    CABlockIterator.new(self, *blocks)
  end
end

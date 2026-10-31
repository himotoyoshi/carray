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
    # Each tile is read through a view with one axis per tile position and
    # one per cell in the tile, twice the source's rank.
    if 2 * source.ndim > CA_RANK_MAX
      raise ArgumentError,
            "blocks: a rank #{source.ndim} array would need #{2 * source.ndim} " \
            "axes for its tiles, beyond the limit of #{CA_RANK_MAX}; " \
            "blocks works up to rank #{CA_RANK_MAX / 2}"
    end

    @sndim   = source.ndim
    offsets  = Array.new(@sndim, 0)
    @sizes   = Array.new(@sndim)
    blocks.each_with_index do |b, i|
      if b.is_a?(Range)
        unless b.begin.is_a?(Integer) && b.end.is_a?(Integer)
          raise TypeError, "blocks: axis #{i} takes a Range of Integer positions, got #{b.inspect}"
        end
        offsets[i] = b.begin
        @sizes[i]  = b.end - b.begin + (b.exclude_end? ? 0 : 1)
      elsif b.is_a?(Integer)
        @sizes[i]  = b
      else
        raise TypeError, "blocks: a tile size must be an Integer (got #{b.class})"
      end
      if @sizes[i] < 1
        raise ArgumentError, "blocks: tile size on axis #{i} must be >= 1"
      end
    end

    # Absorb a leading offset with a zero-copy pre-slice, so the tile geometry
    # below always starts at index 0.
    @source =
      if source.scalar?
        source.flatten        # a CScalar takes no index; its one-cell view does
      elsif offsets.all?(&:zero?)
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
    grids = nil
    faces = nil
    single = true
    each_region do |strip_ranges, tiles, out_ranges|
      view = @source[*strip_ranges].block_view(*tiles)
      res  = yield(view, tiles)
      single = false if res.is_a?(Array)
      res  = [res] unless res.is_a?(Array)
      faces ||= res.map { |r| r.face? ? r : nil }
      parts = res.map { |r| r.face? ? face_grid_part(r) : r }
      grids ||= parts.map { |r| CArray.new(r.data_type, @shape, bytes: r.bytes) }
      parts.each_index { |k| grids[k][*out_ranges] = parts[k] }
    end
    unless grids
      # An empty source has no region.  A view with unit tiles has no cells
      # either; reducing it gives each output's type for the empty grid.
      res = yield(@source.block_view(*[1] * @sndim), [1] * @sndim)
      single = !res.is_a?(Array)
      res = [res] unless res.is_a?(Array)
      faces = res.map { |r| r.face? ? r : nil }
      grids = res.map { |r| r = face_grid_part(r) if r.face?; CArray.new(r.data_type, @shape, bytes: r.bytes) }
    end
    outs = grids.each_index.map { |k| faces[k] ? face_grid(grids[k], faces[k]) : grids[k] }
    single ? outs[0] : outs
  end

  # A region result that is a Face (a CATime mean, a CATimedelta stddev) is
  # assembled on its storage and the Face is put back on the whole grid;
  # assembling the Face itself would copy its surface bytes into an array that
  # no longer knows it is one.  A CAConstString's storage points into its own
  # buffer, which the regions do not share, so it is assembled as strings.
  def face_grid_part (r)
    r.is_a?(CAConstString) ? r.to_string.parent : r.parent
  end

  def face_grid (grid, face)
    return CArray.const_string(grid, encoding: face.encoding) if face.is_a?(CAConstString)
    grid.face_lift(face)
  end

  # Fold every region with a single core reduction `op` (the tier-1 shape).
  def fold (op, **kw)
    assemble { |view, _tiles| view.public_send(op, axis: @tile_axes, **kw) }
  end

  public

  # ---- named reductions (core delegation, drift zero) -------------------
  #
  # A per-tile fold to one value over the trailing tile axes is exactly a core
  # per-axis reduction over those axes, so every reduction delegates to
  # `block_view.<op>(axis: tile_axes, ...)` per region.  This inherits the core
  # data type, mask, empty / all-masked (identity vs UNDEF) and epsilon-close
  # contracts unchanged.  `min_count:` / `fill_value:` pass straight to the core.

  # @!method sum(min_count: nil, fill_value: nil)
  #   Per-tile sum.
  #   @param min_count [Integer, nil] fewest cells that must be present
  #     for a result; a piece with fewer comes back masked.
  #   @param fill_value [Object, nil] value to put in place of a masked
  #     result instead of leaving it masked.
  #   @return [CArray] tile-grid shaped
  # @!method accumulate(min_count: nil, fill_value: nil)
  #   Per-tile sum kept in the source's own data type, wrapping at its
  #   width, as the core `accumulate` does -- `sum` answers in the type
  #   the core promotes to (float64 for integers).
  #   @param min_count [Integer, nil] fewest cells that must be present
  #     for a result; a piece with fewer comes back masked.
  #   @param fill_value [Object, nil] value to put in place of a masked
  #     result instead of leaving it masked.
  #   @return [CArray] tile-grid shaped
  # @!method prod(min_count: nil, fill_value: nil)
  #   Per-tile product.
  #   @param min_count [Integer, nil] fewest cells that must be present
  #     for a result; a piece with fewer comes back masked.
  #   @param fill_value [Object, nil] value to put in place of a masked
  #     result instead of leaving it masked.
  #   @return [CArray] tile-grid shaped
  # @!method mean(min_count: nil, fill_value: nil)
  #   Per-tile arithmetic mean.
  #   @param min_count [Integer, nil] fewest cells that must be present
  #     for a result; a piece with fewer comes back masked.
  #   @param fill_value [Object, nil] value to put in place of a masked
  #     result instead of leaving it masked.
  #   @return [CArray] tile-grid shaped
  # @!method min(min_count: nil, fill_value: nil)
  #   Per-tile minimum.
  #   @param min_count [Integer, nil] fewest cells that must be present
  #     for a result; a piece with fewer comes back masked.
  #   @param fill_value [Object, nil] value to put in place of a masked
  #     result instead of leaving it masked.
  #   @return [CArray] tile-grid shaped
  # @!method max(min_count: nil, fill_value: nil)
  #   Per-tile maximum.
  #   @param min_count [Integer, nil] fewest cells that must be present
  #     for a result; a piece with fewer comes back masked.
  #   @param fill_value [Object, nil] value to put in place of a masked
  #     result instead of leaving it masked.
  #   @return [CArray] tile-grid shaped
  # @!method variance(min_count: nil, fill_value: nil)
  #   Per-tile sample variance (divisor `n - 1`).
  #   @param min_count [Integer, nil] fewest cells that must be present
  #     for a result; a piece with fewer comes back masked.
  #   @param fill_value [Object, nil] value to put in place of a masked
  #     result instead of leaving it masked.
  #   @return [CArray] tile-grid shaped
  # @!method stddev(min_count: nil, fill_value: nil)
  #   Per-tile sample standard deviation (divisor `n - 1`).
  #   @param min_count [Integer, nil] fewest cells that must be present
  #     for a result; a piece with fewer comes back masked.
  #   @param fill_value [Object, nil] value to put in place of a masked
  #     result instead of leaving it masked.
  #   @return [CArray] tile-grid shaped
  # @!method all
  #   Whether every cell of each tile is true.
  #   Takes no `min_count:` or `fill_value:`, as the core `all` does not.
  #   @return [CArray] tile-grid shaped
  # @!method any
  #   Whether any cell of each tile is true.
  #   Takes no `min_count:` or `fill_value:`, as the core `any` does not.
  #   @return [CArray] tile-grid shaped
  # @!method variancep(min_count: nil, fill_value: nil)
  #   Per-tile population variance (divisor `n`).
  #   @param min_count [Integer, nil] fewest cells that must be present
  #     for a result; a piece with fewer comes back masked.
  #   @param fill_value [Object, nil] value to put in place of a masked
  #     result instead of leaving it masked.
  #   @return [CArray] tile-grid shaped
  # @!method stddevp(min_count: nil, fill_value: nil)
  #   Per-tile population standard deviation (divisor `n`).
  #   @param min_count [Integer, nil] fewest cells that must be present
  #     for a result; a piece with fewer comes back masked.
  #   @param fill_value [Object, nil] value to put in place of a masked
  #     result instead of leaving it masked.
  #   @return [CArray] tile-grid shaped
  CArray.send(:define_named_methods, self,
              [:sum, :accumulate, :prod, :mean, :min, :max, :variance, :stddev,
               :variancep, :stddevp], :fold_reduction)

  private def fold_reduction (op, min_count: nil, fill_value: nil)
    if FACE_WINNER_INDEX.key?(op) && @source.face?
      return face_winner(FACE_WINNER_INDEX[op], min_count, fill_value)
    end
    kw = {}
    kw[:min_count]  = min_count  unless min_count.nil?
    kw[:fill_value] = fill_value unless fill_value.nil?
    fold(op, **kw)
  end

  CArray.send(:define_named_methods, self, [:all, :any], :fold_with_keywords)

  private def fold_with_keywords (op, **kw)
    fold(op, **CAIterator.reduce_keywords(op, kw))
  end

  # @!method first
  #   Per-tile first present value, in row-major order within the tile;
  #   UNDEF for a tile with none.
  #   @return [CArray] tile-grid shaped
  # @!method last
  #   Per-tile last present value; UNDEF for a tile with none.
  #   @return [CArray] tile-grid shaped
  # @!method nunique
  #   Per-tile number of distinct present values (int64); 0 for a tile with
  #   none.
  #   @return [CArray] tile-grid shaped
  #
  # These take no `min_count:` or `fill_value:`, as the core ones do not.
  CArray.send(:define_named_methods, self, [:first, :last, :nunique], :fold_with_keywords)

  # A Face's minimum and maximum are cells of the Face, so they are gathered
  # from the source by the winner's address.  Assembling the per-region results
  # instead copies the Face's storage into an array that no longer knows it is
  # one: a CATime came back as 8-byte strings.
  FACE_WINNER_INDEX = { min: :min_index, max: :max_index }.freeze
  Ractor.make_shareable(FACE_WINNER_INDEX)
  private_constant :FACE_WINNER_INDEX

  # ---- count family and elements ----------------------------------------

  # @overload count(v = <none>)
  #   Per-tile count.  No argument counts present (non-masked) cells (fewer at a
  #   partial edge tile); `count(UNDEF)` counts masked cells; `count(v)` counts
  #   cells equal to `v`.
  #   @return [CArray] tile-grid shaped
  def count (*args, **kw)
    return count_not_masked(**kw) if args.empty?
    kw = CAIterator.reduce_keywords(:count, kw)
    # block_view is a CAStride, so #count is not shadowed; dispatch
    # CArray#count explicitly anyway, matching the family regularity.
    assemble { |view, _| CArray.instance_method(:count).bind_call(view, *args, axis: @tile_axes, **kw) }
  end

  # @overload count_not_masked
  #   Per-tile count of present (non-masked) cells.  For a partial edge tile
  #   this is the real cell count (the OOB cells are not present).
  #   @return [CArray]
  def count_not_masked (**kw)
    fold(:count_not_masked, **CAIterator.reduce_keywords(:count_not_masked, kw))
  end

  # @overload count_masked
  #   Per-tile count of masked cells.  Equals `elements - count_not_masked`;
  #   the OOB cells of a partial edge tile count here.
  #   @return [CArray]
  def count_masked (**kw)
    kw   = CAIterator.reduce_keywords(:count_masked, kw)
    need = CArray.__present_cells_needed_per_result_cell__(:count_masked, kw[:min_count], 0)
    out  = elements - count_not_masked
    # A count of the mask reads every cell of the tile.
    out[elements.lt(need)] = UNDEF if need > 0
    CArray.__fill_undefined_result_cells__(out, kw[:fill_value])
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
    if @source.face?
      return [min(min_count: min_count, fill_value: fill_value),
              max(min_count: min_count, fill_value: fill_value)]
    end
    kw = {}
    kw[:min_count]  = min_count  unless min_count.nil?
    kw[:fill_value] = fill_value unless fill_value.nil?
    assemble { |view, _| view.minmax(axis: @tile_axes, **kw) }
  end

  # @!method min_index
  #   Per-tile position of the minimum, as a flat index within the tile (a
  #   partial edge tile indexes within its own present cells).
  #   @return [CArray] tile-grid shaped
  # @!method max_index
  #   Per-tile position of the maximum (tile-local flat index).
  #   @return [CArray]
  [:min_index, :max_index].each do |op|
    class_eval <<~RUBY, __FILE__, __LINE__ + 1
      def #{op} (**kw)
        kw = CAIterator.reduce_keywords(:#{op}, kw)
        assemble { |view, _| view.#{op}(axis: @tile_axes, **kw) }
      end
    RUBY
  end

  # @overload min_addr
  #   Per-tile flat SOURCE address of the minimum — which cell of the source
  #   holds it, so `source.reshape(source.elements)[bi.min_addr]` are the tile
  #   minima. Unlike `min_index` (the tile-local position) this indexes back
  #   into the original array. An all-masked tile is a masked cell.
  #   @return [CArray] tile-grid shaped int64
  def min_addr (**kw); winner_addr(:min_index, kw); end

  # @overload max_addr
  #   Per-tile flat source address of the maximum. See {#min_addr}.
  #   @return [CArray] tile-grid shaped int64
  def max_addr (**kw); winner_addr(:max_index, kw); end

  private

  # Per-tile minimum or maximum of a Face source, gathered from the source by
  # the winner's address so the result is the Face itself.  An all-masked tile,
  # and with `min_count` a tile with too few present cells, is a masked cell.
  def face_winner (idx_op, min_count, fill_value)
    addr = winner_addr(idx_op)
    need = CArray.__present_cells_needed_per_result_cell__(idx_op == :min_index ? :min : :max, min_count, 0)
    addr[count_not_masked.lt(need)] = UNDEF if need > 0
    src   = @source.reshape(@source.elements)
    empty = addr.is_masked
    return src[addr].copy unless empty.any
    # A masked index would read as masked, but gathering by one gives the
    # source a mask, so an empty tile takes a placeholder address instead.
    # Pointing it at a masked cell of the source
    # carries the mask through the gather, which a read-only Face (whose copy
    # cannot be written) needs.  Otherwise mask the placeholder afterwards.
    if fill_value.nil? && src.has_mask? && (hole = src.is_masked.where).elements > 0
      return src[addr.strip_mask(hole[0])].copy
    end
    out = src[addr.strip_mask(0)].copy
    out[empty] = fill_value.nil? ? UNDEF : fill_value
    out
  end

  # Per-tile source address of the winner. The tile-local flat index (min_index /
  # max_index) is looked up in a source-address companion tiled the same way, so
  # the tile geometry is reused rather than recomputed. An all-masked tile yields
  # a masked index; it is gathered at 0 and re-masked in the result.
  def winner_addr (idx_op, kw = {})
    kw    = CAIterator.reduce_keywords(idx_op, kw)
    saddr = CArray.int64(*@source.shape).seq!
    out = nil
    each_region do |strip_ranges, tiles, out_ranges|
      vview = @source[*strip_ranges].block_view(*tiles)
      sview = saddr[*strip_ranges].block_view(*tiles)
      mi    = vview.public_send(idx_op, axis: @tile_axes, **kw.slice(:min_count))  # tile-local flat index
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
    CArray.__fill_undefined_result_cells__(out || CArray.int64(*@shape), kw[:fill_value])
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
      order = vview.copy.reshape(*(grid + [cells])).sort_index(axis: @sndim)
      src_sorted = sview.reshape(*(grid + [cells])).take_along_axis(order, axis: @sndim)
      out[*strip_ranges].block_view(*tiles)[] = src_sorted.reshape(*(grid + tiles))
    end
    out
  end

  # @overload wsum(weights)
  #   Per-tile weighted sum; `weights` is shaped like one full tile (`Π b_i`).
  #   At a partial edge tile the weight kernel is sliced to the present cells.
  #   @return [CArray]
  def wsum (weights, **kw)
    kw = CAIterator.reduce_keywords(:wsum, kw)
    weighted(weights) { |view, w| view.wsum(w, axis: @tile_axes, **kw) }
  end

  # @overload wmean(weights)
  #   Per-tile weighted mean; `weights` shaped like one full tile.
  #   @return [CArray]
  def wmean (weights, **kw)
    kw = CAIterator.reduce_keywords(:wmean, kw)
    weighted(weights) { |view, w| view.wmean(w, axis: @tile_axes, **kw) }
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
  # order-stat.  Masked cells are left out, as in `CArray#median(axis:)`.

  # @overload median
  #   Per-tile median.  @return [CArray]
  def median (**kw)
    kw = CAIterator.reduce_keywords(:median, kw)
    order_stat { |v, axis| v.median(axis: axis, **kw) }
  end

  # @overload percentile(*pers)
  #   Per-tile percentile(s).  One argument returns one CArray, several an array
  #   of CArrays (as `CArray#percentile`).
  #   @return [CArray, Array<CArray>]
  def percentile (*pers, **kw)
    kw = CAIterator.reduce_keywords(:percentile, kw)
    order_stat { |v, axis| v.percentile(*pers, axis: axis, **kw) }
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
    pout = CArray.new(padded_source.data_type, padded_source.shape, bytes: padded_source.bytes)
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

  # @!method cumsum
  #   Per-tile inclusive running sum (float64), source-shaped.
  #   @return [CArray]
  # @!method cumprod
  #   Per-tile inclusive running product (float64), source-shaped.
  #   @return [CArray]
  # @!method cummax
  #   Per-tile inclusive running maximum (value data type), source-shaped.
  #   @return [CArray]
  # @!method cummin
  #   Per-tile inclusive running minimum (value data type), source-shaped.
  #   @return [CArray]
  # @!method cumcount
  #   Per-tile running count of present cells (int64), source-shaped.
  #   @return [CArray]
  CArray.send(:define_named_methods, self,
              [:cumsum, :cumprod, :cummax, :cummin, :cumcount], :scan_tiles)

  # A scan takes no arguments here.
  private def scan_tiles (op, *args)
    unless args.empty?
      raise ArgumentError, "wrong number of arguments (given #{args.size}, expected 0)"
    end
    block_scan(op)
  end

  # @overload lag(n = 1)
  #   Per-tile value `n` steps earlier, counting the tile's cells row-major;
  #   UNDEF where the tile has none, so a lag never reaches into another
  #   tile. A partial edge tile counts only the cells it has.
  #   @return [CArray] source-shaped
  def lag (n = 1)
    unless n.is_a?(Integer)
      raise TypeError, "lag: n must be an Integer (got #{n.class})"
    end
    tile_wise { |rows, axis| rows.lag(n, axis: axis) }
  end

  # @overload strip_mask(method:)
  #   Per-tile fill of the masked cells, counting the tile's cells row-major:
  #   `:forward` / `:ffill` or `:backward` / `:bfill`. A fill never reaches
  #   into another tile, so a masked cell with nothing to carry in its tile
  #   stays masked.
  #   @return [CArray] source-shaped
  def strip_mask (method:)
    CAIterator.hold_backward?(method)
    tile_wise { |rows, axis| rows.strip_mask(method: method, axis: axis) }
  end

  # @overload order(descending: false, method: :ordinal, kind: :quick)
  #   Per-tile rank of each cell among the tile's cells (int64, `0` the
  #   smallest), as `CArray#order` ranks them; a partial edge tile ranks only
  #   the cells it has. The keywords are those of `CArray#order`.
  #   @return [CArray] source-shaped
  def order (**kw)
    tile_wise { |rows, axis| rows.order(axis: axis, **kw) }
  end

  private

  # A source-shaped result built tile by tile: the block gets a region's
  # tiles as rows (one tile's cells, row-major, along +axis+) and gives back
  # rows of the same shape. Each region has whole tiles of one size, so a
  # partial edge tile is its own cells rather than cells and padding.
  def tile_wise
    out = nil
    each_region do |strip_ranges, tiles, _out_ranges|
      view  = @source[*strip_ranges].block_view(*tiles)
      grid  = view.shape[0, @sndim]
      found = yield(view.copy.reshape(*grid, tiles.inject(1, :*)), @sndim)
                .reshape(*grid, *tiles)
      out ||= tile_output(found)
      out[*strip_ranges].block_view(*tiles)[] = tile_values(out, found)
    end
    # a source with no cells has no region; its one-cell rows give the type
    out || yield(@source.copy.reshape(*@source.shape, 1), @sndim).reshape(*@source.shape)
  end

  # Drive a within-tile segment scan: scan each tile flattened row-major and
  # scatter back to a source-shaped result.  The output data type is taken from the
  # first tile's scan (all tiles share it); the padded margin is UNDEF and the
  # OOB cells of a partial edge tile are cropped from the result.
  def block_scan (op, *args)
    tgv  = tile_grid_view
    nils = Array.new(@sndim, nil)
    pout = nil
    pgv  = nil
    CArray.each_index(*@shape) do |*g|
      tile    = tgv[*g, *nils]
      scanned = tile.copy.reshape(tile.elements).public_send(op, *args).reshape(*@sizes)
      unless pout
        pout = CArray.new(scanned.data_type, padded_source.shape, bytes: scanned.bytes)
        pout[] = UNDEF
        pgv  = pout.block_view(*@sizes)
      end
      pgv[*g, *nils] = scanned
    end
    # a source with no cells has no tile; its own scan gives the type
    return @source.copy.reshape(@source.elements).public_send(op, *args).reshape(*@source.shape) unless pout
    pout[*@sndim.times.map { |i| 0...@source.shape[i] }].copy
  end

  # A source-shaped array that can hold what #tile_wise gives: of its kind,
  # or an object array for a read-only Face, which cannot be written cell by
  # cell.
  def tile_output (lagged)
    if lagged.face? && lagged.read_only?
      CArray.object(*@source.shape)
    else
      lagged.__send__(:blank_like, @source.shape)
    end
  end

  # The values as +out+ can hold them: a Face going into an object array
  # goes as its surface values, not its storage.
  def tile_values (out, lagged)
    return lagged unless out.data_type == CA_OBJECT && lagged.face?
    CArray.object(*lagged.shape) { lagged.to_a }
  end

  # A padded entity whose interior holds the source and whose partial-edge
  # margin is masked (UNDEF), sized to exactly cover the ceil tile grid.  When
  # the source already divides evenly this is the source itself (no copy), so
  # the tiles alias it.  Kept for one call; feeds the iterate escape hatches.
  def padded_source
    @padded_source ||= begin
      pshape = @sndim.times.map { |i| @shape[i] * @sizes[i] }
      if pshape == @source.shape.to_a
        @source
      else
        pad = @source.__send__(:blank_like, pshape)   # a Face stays one
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

  # lag and strip_mask(method:) give the source's values moved or held in
  # place, so the result shows the source's attributes, as CArray#lag and
  # CArray#strip_mask(method:) do.
  prepend(Module.new do
    def lag (*args, **keywords) = @source.__send__(:carry_attrs, super)
    def strip_mask (**keywords) = @source.__send__(:carry_attrs, super)
  end)

  read_source_per_call :@padded_source, :@tile_grid_view
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
  #   @raise [ArgumentError] when `self` has a rank above `CA_RANK_MAX / 2`
  #     (8): the tiles are read through a view of twice the rank.
  def blocks (*blocks)
    CABlockIterator.new(self, *blocks)
  end
end

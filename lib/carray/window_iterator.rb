# ----------------------------------------------------------------------------
#
#  carray/window_iterator.rb
#
#  CAWindowIterator — a rolling (sliding-window) reduction dispatcher, the
#  Window member of the 3.0 iterator family (sibling of CASlabIterator /
#  CACategoricalIterator).  Where a slab iterator folds each non-overlapping
#  slab, a window iterator folds an OVERLAPPING window centred on every anchor
#  cell, so the output is shaped like the source (a rolling result) rather
#  than an outer shape.
#
#      sw = a.windows(-1..1)          # width-3 window per anchor
#      sw.mean                        # rolling mean, shaped like a
#      sw.correlate(kernel)           # bounded cross-correlation
#      sw.convolve(kernel)            # bounded convolution (kernel flipped)
#
#  Engine: build a padded entity once (source copied into the interior, the
#  margins filled by the boundary policy), take its `sliding_windows` view
#  (a pure strided view over the padded buffer), and run a core reduction over
#  the trailing window axes.  One vectorized pass; the named reductions
#  delegate straight to the core reduction, so their data type / mask / empty
#  (ERI) / epsilon contracts are the core's, unchanged.  This replaces the 2.0
#  per-anchor C engine (ext/ca_iter_window.c, retired).
#
#  Boundary policy is chosen at construction with `bounds:`:
#
#      :skip      (default) UNDEF margin; a window near the edge folds only its
#                 in-bounds cells (masked pad cells are skipped by the core
#                 reduction).  Output is reference-shaped.
#      :nearest   edge-replicated margin (the nearest source cell extends
#                 outward).  Output is reference-shaped, margin cells are real.
#      :truncate  no pad; only fully in-bounds anchors are produced, so the
#                 output shrinks to `N_i - w_i + 1` per axis.  Zero-copy (the
#                 source's own sliding_windows view), the valid-convolution
#                 mode.
#
#  How the boundary spectrum lands on the core reduction: with :skip the
#  margin is UNDEF, so `min_count:` (require this many present cells) and
#  `fill_value:` (replace an UNDEF result) — both passed straight through to
#  the core reduction — express the full spectrum from "fold whatever is
#  present" to "full windows only, edges filled".  There is no window-specific
#  strictness knob.
#
#  The class name is kept from 2.0 (the concept — a window — is stable);
#  this is the Ruby family member that supersedes the C engine.  Loaded
#  lazily via autoload from
#  lib/carray/autoload_carray.rb the first time `a.windows(...)` is used.
#
# ----------------------------------------------------------------------------

require "carray"

# Rolling (sliding-window) reduction dispatcher — the Window member of the
# iterator family (sibling of `CASlabIterator` / {CABlockIterator} /
# `CACategoricalIterator`).  It folds an overlapping window centred on every
# anchor cell, so the result is shaped like the source rather than reduced.
#
# Obtained from `CArray#windows`, not constructed directly.
#
# @example
#   sw = a.windows(-1..1)     # width-3 window per anchor
#   sw.mean                   # rolling mean, shaped like a
#   sw.correlate(kernel)      # bounded cross-correlation
class CAWindowIterator < CAIterator

  # @overload initialize(source, ranges, bounds: :skip, fill_value: nil)
  #   Builds a window iterator over `source` with a per-axis offset range.
  #   Each `ranges[i]` is a `lo..hi` giving the window's offset span around
  #   an anchor (`a.windows(-1..1)` is a centred width-3 window; `0..2` is
  #   forward-looking).  `bounds:` selects the margin policy (`:skip` /
  #   `:nearest` / `:truncate`).  `fill_value:` is a constant margin value
  #   (an escape for `:constant` padding); when given it overrides `:skip`.
  #
  #   For backward compatibility `initialize(window_view)` accepts a CAWindow
  #   view (the old `CAWindowIterator.new(a.window(...))` form): the geometry
  #   (offset ranges, bounds, fill value) is read back from the view.
  #
  #   @param source [CArray, CAWindow] the array to roll over, or a CAWindow
  #     view to read the geometry from.
  #   @param ranges [Array<Range>] per-axis offset ranges.
  #   @param bounds [Symbol] `:skip` / `:nearest` / `:truncate`.
  #   @param fill_value [Object, nil] constant margin value, overriding :skip.
  def initialize (source, *ranges, bounds: :skip, fill_value: nil)
    if source.is_a?(CArray) && source.obj_type == CA_OBJ_WINDOW
      # Backward-compat: read geometry from a CAWindow view built by #window.
      # start[i] = lo, dim[i] (window width) = w, so hi = lo + w - 1.
      win     = source
      @source = win.parent
      widths  = win.count
      @ranges = win.start.each_with_index.map { |lo, i| lo..(lo + widths[i] - 1) }
      # The legacy #window default is FILL (constant), whose value is the
      # view's fill_value; map that to a :constant margin.
      @bounds     = :constant
      @fill_value = win.fill_value
    else
      @source     = source
      @ranges     = ranges.flatten(0)
      @bounds     = bounds
      @fill_value = fill_value
    end

    unless @ranges.size == @source.ndim
      raise ArgumentError,
            "windows: expected #{@source.ndim} ranges (one per axis), " \
            "got #{@ranges.size}"
    end

    @sndim  = @source.ndim
    @widths = @ranges.map { |r| r.end - r.begin + 1 }
    @lefts  = @ranges.map { |r| [0, -r.begin].max }   # left margin per axis
    @rights = @ranges.map { |r| [0,  r.end ].max }    # right margin per axis

    # A constant fill_value: overrides :skip (constant margin escape hatch).
    @bounds = :constant if @fill_value != nil && @bounds == :skip

    # Trailing window axes of the sliding_windows view: [ndim .. 2*ndim-1].
    @window_axes = (@sndim...(2 * @sndim)).to_a

    # Output iteration space (reference-shaped, except :truncate, which keeps
    # only the anchors whose window lies wholly inside the source), and where
    # each axis's first window starts in the buffer the windows are read from.
    # A window that does not cover its own anchor -- `windows(1..2)`, the two
    # cells after this one -- starts further along than the margin allows for,
    # which is what @origins carries.
    rshape = @source.shape
    if @bounds == :truncate
      first  = @ranges.map { |r| [0, -r.begin].max }
      last   = @sndim.times.map { |i| [rshape[i] - 1, rshape[i] - 1 - @ranges[i].end].min }
      @shape = @sndim.times.map { |i| [last[i] - first[i] + 1, 0].max }
      @origins = @ranges.map { |r| [r.begin, 0].max }
    else
      @shape = rshape.dup
      @origins = @sndim.times.map { |i| @lefts[i] + @ranges[i].begin }
    end
    @ndim = @shape.size
    self
  end

  # @overload source
  #   Returns the array being rolled over.
  #   @return [CArray]
  attr_reader :source

  # @overload bounds
  #   Returns the boundary policy symbol.
  #   @return [Symbol]
  attr_reader :bounds

  # ---- padded entity + sliding_windows view -----------------------------
  #
  # The engine: pad the source once (:skip -> UNDEF, :nearest -> edge, :constant
  # -> value; :truncate does not pad), then take a sliding_windows view.  Both
  # are memoised: every named reduction reuses the one pad + one view.

  # @overload sliding_view
  #   Returns the sliding_windows view feeding the reductions.  For :truncate
  #   this is the source's own view (zero-copy); otherwise it is the view over
  #   the padded entity.
  #   @return [CArray]
  def sliding_view
    @sliding_view ||= anchored_buffer.sliding_windows(*@widths)
  end

  private

  # The stretch of the padded buffer the windows are taken from: it begins at
  # the first window and holds one window per anchor.  For a window that covers
  # its own anchor and a boundary policy that pads, that is the whole buffer.
  def anchored_buffer
    buffer = padded_entity
    wanted = @ndim.times.map { |k| @origins[k]...(@origins[k] + @shape[k] + @widths[k] - 1) }
    return buffer if wanted.each_with_index.all? { |range, k|
      range.begin.zero? && range.end == buffer.dim[k]
    }
    buffer[*wanted]
  end

  # Build the padded entity (or, for :truncate, the source itself).  Memoised.
  def padded_entity
    @padded_entity ||=
      if @bounds == :truncate
        @source
      else
        pad_source(@source, @lefts, @rights, pad_mode, @fill_value)
      end
  end

  def pad_mode
    case @bounds
    when :skip     then :masked
    when :nearest  then :edge
    when :constant then :constant
    else
      raise ArgumentError,
            "windows: unknown bounds #{@bounds.inspect} " \
            "(expected :skip, :nearest, :truncate)"
    end
  end

  # Private pad helper: build a padded entity from `src` with per-axis
  # (left, right) margins and one of three fill modes.  Not a public
  # CArray#pad -- window construction and convolution use it internally, the
  # escape hatches yield from the padded entity, so users never call it.  A
  # standalone public CArray#pad is a possible future promotion.
  #
  #   :constant  margin cells set to `value` (0 when value is nil).
  #   :edge      margin cells replicate the nearest source edge cell.
  #   :masked    margin cells are UNDEF (masked); reductions skip them.
  #
  # One allocation, the source copied into the interior region, then the
  # margins filled per mode.
  def pad_source (src, lefts, rights, mode, value)
    nd    = src.ndim
    shape = src.shape
    pshape = nd.times.map { |i| shape[i] + lefts[i] + rights[i] }
    pad    = CArray.new(src.data_type, pshape)

    # Fill the whole buffer first, then overwrite the interior with the source.
    case mode
    when :constant
      pad[] = (value.nil? ? 0 : value)
    when :masked
      pad[] = UNDEF
    when :edge
      # Provisional fill; the edge margins are written below from the source.
      pad[] = 0
    end

    interior = nd.times.map { |i| lefts[i]...(lefts[i] + shape[i]) }
    pad[*interior] = src

    replicate_edges(pad, lefts, rights, shape) if mode == :edge

    pad
  end

  # Edge-replicate the margins of a padded buffer whose interior already holds
  # the source.  Per axis, the left margin rows copy the first interior row and
  # the right margin rows copy the last; done axis by axis over the whole
  # buffer (including corners, which pick up the replicated neighbours from an
  # earlier axis, matching the standard edge-pad of corners).
  def replicate_edges (pad, lefts, rights, shape)
    pad.ndim.times do |ax|
      lo = lefts[ax]
      hi = lefts[ax] + shape[ax] - 1        # last interior index on this axis
      if lefts[ax] > 0
        src_sel = axis_selector(pad.ndim, ax, lo)          # first interior row
        lefts[ax].times do |m|
          pad[*axis_selector(pad.ndim, ax, m)] = pad[*src_sel]
        end
      end
      if rights[ax] > 0
        src_sel = axis_selector(pad.ndim, ax, hi)          # last interior row
        (hi + 1...pad.shape[ax]).each do |m|
          pad[*axis_selector(pad.ndim, ax, m)] = pad[*src_sel]
        end
      end
    end
  end

  # How many of one axis's window offsets fall inside the source, per anchor.
  # A window away from the edges holds all of them, so the vector is the window
  # width everywhere but the two ends, and only the ends -- at most one window
  # width of cells each -- are counted out.
  def axis_cell_counts (k)
    length = @shape[k]
    first  = @ranges[k].begin
    last   = @ranges[k].end
    counts = CArray.int64(length)
    counts[] = @widths[k]
    truncated_at_the_start = [[-first, 0].max, length].min
    truncated_at_the_end   = [[length - last, 0].max, 0].max
    indices = (0...truncated_at_the_start).to_a | (truncated_at_the_end...length).to_a
    indices.each do |i|
      low  = [first, -i].max
      high = [last, length - 1 - i].min
      counts[i] = [high - low + 1, 0].max
    end
    counts
  end

  # An index list of length `nd` that is `nil` (full range) on every axis
  # except `ax`, which is pinned to `k`.
  def axis_selector (nd, ax, k)
    sel = Array.new(nd)
    sel[ax] = k
    sel
  end

  public

  # ---- named reductions (core delegation, drift zero) -------------------
  #
  # A per-window fold to one value over the trailing window axes is exactly a
  # core per-axis reduction over those axes, so every reduction delegates to
  # `sliding_view.<op>(axis: window_axes, ...)`.  This inherits the core data type,
  # mask, empty / all-masked (identity vs UNDEF) and epsilon-close contracts
  # unchanged.  `min_count:` / `fill_value:` pass straight to the core (the
  # boundary strictness + result fill knobs).

  # @overload sum(min_count: nil, fill_value: nil)
  #   Rolling sum, delegating to `sliding_view.sum(axis: window_axes)`.
  #   @return [CArray] reference-shaped (or shrunk, for :truncate)
  # @overload accumulate(min_count: nil, fill_value: nil)
  #   Rolling sum in the source's own data type, wrapping at its width, as the
  #   core `accumulate` does.  `sum` answers in the type the core promotes to
  #   (float64 for integers), which for a window over bytes moves eight times
  #   the bytes; this is the spelling for staying in the type when the window
  #   cannot overflow it.
  #   @return [CArray] reference-shaped (or shrunk, for :truncate)
  # The rest are analogous: prod / mean / min / max, sample and population
  # variance / stddev, all / any, fused minmax, and the window-local position
  # min_index / max_index (index within the window axes).
  [:sum, :accumulate, :prod, :mean, :min, :max, :variance, :stddev, :all, :any,
   :variancep, :stddevp, :minmax, :min_index, :max_index].each do |op|
    class_eval <<~RUBY, __FILE__, __LINE__ + 1
      def #{op} (min_count: nil, fill_value: nil)
        folded = fold_by_offset(:#{op}, min_count, fill_value)
        return folded unless folded.nil?
        kw = {}
        kw[:min_count]  = min_count  unless min_count.nil?
        kw[:fill_value] = fill_value unless fill_value.nil?
        sliding_view.#{op}(axis: @window_axes, **kw)
      end
    RUBY
  end

  # @overload min_addr
  #   Rolling flat SOURCE address of the window minimum — which source cell holds
  #   it, so `source.reshape(source.elements)[sw.min_addr]` are the window minima.
  #   Unlike `min_index` (the position within the window) this indexes back into
  #   the original array. The winner's source cell is the anchor plus its window
  #   offset; with `bounds: :nearest` a winning margin cell resolves to the edge
  #   source cell it replicates, and with `bounds: :constant` (or `fill_value:`)
  #   a winning margin cell has no source address and is a masked result.
  #   @return [CArray] reference-shaped (or shrunk, for :truncate)
  def min_addr; window_winner_addr(:min_index); end

  # @overload max_addr
  #   Rolling flat source address of the window maximum. See {#min_addr}.
  #   @return [CArray] reference-shaped (or shrunk, for :truncate)
  def max_addr; window_winner_addr(:max_index); end

  private

  # ---- folding by offset instead of by anchor ---------------------------
  #
  # Delegating to `sliding_view.<op>(axis: window_axes)` folds the window axes,
  # which are the innermost ones, so the core pays its per-fiber setup once per
  # output cell -- about 10 ns, whatever the window holds.  For a 3x3 window
  # that setup is nine tenths of the time.
  #
  # The same fold can be run the other way round: walk the window offsets, and
  # for each one add the whole shifted plane into an accumulator.  Then the
  # setup is paid once per offset rather than once per output cell, and every
  # pass is a straight walk over contiguous memory.  It costs one pass per
  # offset, so it only pays while the window is small; the crossover moves with
  # rank and data type, but stays above width 5 on every axis in every
  # combination measured (see devel/PROPOSAL_WINDOW_OFFSET_ACCUMULATION.md).
  #
  # What is decided here is the order of the fold and which pad it reads; the
  # arithmetic is the core's elementwise kernel, and the result data type is
  # the core's answer for the same reduction (asked below, so it cannot drift).

  # The in-place elementwise kernel that accumulates one offset, per operation.
  # An operation absent here has no identity to accumulate from and always
  # takes the delegating path.
  OFFSET_FOLD = { :sum  => :add!,  :accumulate => :add!,
                  :prod => :mul!,
                  :min  => :pmin!, :max  => :pmax!,
                  :all  => :and!,  :any  => :or! }.freeze

  # Widest window this path takes on any one axis.
  OFFSET_FOLD_MAX_WIDTH = 5

  # Runs the fold by offset, or returns nil when this window is not one it can
  # answer for -- in which case the caller delegates as before.
  def fold_by_offset (op, min_count, fill_value = nil)
    return nil unless op == :mean || OFFSET_FOLD.key?(op)
    return nil if @widths.any? { |width| width > OFFSET_FOLD_MAX_WIDTH }
    return nil if neutral_value(op).nil?

    folded = op == :mean ? fold_mean : accumulate_offsets(op)
    folded = mask_empty_windows(folded) if EMPTY_WINDOW_IS_UNDEFINED.include?(op)
    folded = apply_min_count(folded, min_count)
    # A `fill_value:` on the call replaces a result that came out undefined.
    folded = folded.strip_mask(fill_value) if !fill_value.nil? && folded.has_mask?
    folded
  end

  # The mean is the sum over the same offsets, divided by the number of cells
  # each window folded.  A window that folded nothing divides by one here and
  # is masked out by {#mask_empty_windows} after.
  def fold_mean
    counts = window_cell_counts
    divisor = counts
    if counts.is_a?(CArray) && counts.min.zero?
      divisor = counts.copy
      divisor[counts.eq(0)] = 1
    end
    accumulate_offsets(:sum).to_type(offset_fold_data_type(:mean)) / divisor
  end

  # Walks the window offsets, accumulating each shifted plane into the result.
  def accumulate_offsets (op, base = nil, kernel = nil, data_type = nil)
    base      ||= offset_fold_base(op)
    kernel    ||= OFFSET_FOLD.fetch(op)
    data_type ||= offset_fold_data_type(op)
    accumulator = nil
    offset_grid.each do |offset|
      plane = base[*@ndim.times.map { |k|
        start = @origins[k] + offset[k]
        start...(start + @shape[k])
      }]
      if accumulator.nil?
        accumulator = CArray.new(data_type, @shape)
        accumulator[] = plane
      else
        accumulator.send(kernel, plane)
      end
    end
    accumulator
  end

  # These have no value to give for a window that folded nothing; the ones not
  # listed answer with their identity, which the accumulation already holds.
  EMPTY_WINDOW_IS_UNDEFINED = [:min, :max, :mean].freeze

  def mask_empty_windows (folded)
    return folded unless windows_can_be_empty?
    folded[window_cell_counts.eq(0)] = UNDEF
    folded
  end

  # Whether any window can come out holding nothing at all.  A masked source
  # can leave one empty anywhere.  Without one, it takes a window that reaches
  # past the array and does not cover its own anchor -- `windows(1..2)` at the
  # far edge -- and the count on an axis falls away towards its ends, so the
  # two ends are the only places to look.
  def windows_can_be_empty?
    return true if @source.has_mask?
    return false if window_cell_counts.is_a?(Integer)
    @ndim.times.any? do |k|
      along = axis_cell_counts(k)
      along[0].zero? || along[@shape[k] - 1].zero?
    end
  end

  # `min_count` asks for a result only where the window held that many cells.
  def apply_min_count (folded, min_count)
    return folded if min_count.nil?
    counts = window_cell_counts
    if counts.is_a?(Integer)
      folded[] = UNDEF if counts < min_count
    else
      folded[counts.lt(min_count)] = UNDEF
    end
    folded
  end

  # What stands in for a cell the fold must not see: a margin the boundary
  # policy does not fill, or a masked cell of the source.  For sum, prod, all
  # and any that is the operation's identity.  For min and max it is any value
  # that cannot win, and the array's own extreme is one -- so no table of
  # per-type limits is needed.  Nil means there is none to be had (a source
  # masked everywhere), and the caller delegates instead.
  def neutral_value (op)
    @neutral_value ||= {}
    return @neutral_value[op] if @neutral_value.key?(op)
    @neutral_value[op] =
      case op
      when :sum, :accumulate, :mean then 0
      when :prod       then 1
      when :all        then true
      when :any        then false
      when :min        then source_extreme(:max)
      when :max        then source_extreme(:min)
      end
  end

  def source_extreme (op)
    value = @source.send(op)
    value.equal?(UNDEF) ? nil : value
  end

  # The buffer the offsets are read from: the source with its margins filled
  # per the boundary policy, with any masked cell replaced by the neutral value
  # -- an accumulation propagates a mask where the fold would skip it -- and in
  # the type the result is accumulated in.  Adding across two types runs a
  # different kernel from adding within one, and how much slower that is
  # depends on the pair, the working set and the compiler; converting once is
  # one behaviour everywhere.  It costs a buffer in the wider type, which for
  # a `sum` over bytes is the one case where it does not pay.
  def offset_fold_base (op)
    @offset_fold_base ||= {}
    @offset_fold_base[op] ||=
      begin
        padded =
          if @source.has_mask?
            pad_for(@source.strip_mask(neutral_value(op)), neutral_value(op))
          elsif @bounds == :skip
            pad_source(@source, @lefts, @rights, :constant, neutral_value(op))
          else
            padded_entity
          end
        wanted = offset_fold_data_type(op)
        padded.data_type == wanted ? padded : padded.to_type(wanted)
      end
  end

  # Pads `values` the way this window's boundary policy says, with `outside`
  # standing in for the margin where the policy does not fill one.
  def pad_for (values, outside)
    case @bounds
    when :truncate then values
    when :nearest  then pad_source(values, @lefts, @rights, :edge, nil)
    when :constant then pad_source(values, @lefts, @rights, :constant, @fill_value)
    else                pad_source(values, @lefts, @rights, :constant, outside)
    end
  end

  # How many cells each window holds.  With an unmasked source this follows
  # from the geometry: every boundary policy but `:skip` fills its margins with
  # real values, so the count is the whole window and one Integer says it;
  # `:skip` counts the in-bounds offsets, which is separable -- the count on
  # one axis depends on that axis alone.  A masked source has to be counted for
  # real, by accumulating over the same offsets.
  def window_cell_counts
    return @window_cell_counts unless @window_cell_counts.nil?
    @window_cell_counts =
      if @source.has_mask?
        accumulate_offsets(:sum, pad_for(@source.is_not_masked.int64, 0),
                           :add!, CA_INT64)
      elsif @bounds != :skip
        @widths.inject(:*)
      else
        counts = CArray.int64(*@shape)
        counts[] = 1
        @ndim.times do |k|
          shape = Array.new(@ndim, 1)
          shape[k] = @shape[k]
          counts.mul!(axis_cell_counts(k).reshape(*shape))
        end
        counts
      end
  end

  # The data type the delegating path would have produced, asked of the core
  # itself so the two paths cannot disagree.
  def offset_fold_data_type (op)
    @offset_fold_data_type ||= {}
    @offset_fold_data_type[op] ||=
      CArray.new(@source.data_type, [1, 1]).send(op, axis: [1]).data_type
  end

  # Every offset within the window, as a list of per-axis positions into the
  # padded buffer.
  def offset_grid
    @offset_grid ||=
      @widths.map { |width| (0...width).to_a }
             .inject { |grid, axis| grid.product(axis).map { |pair| Array(pair).flatten } }
             .map { |offset| Array(offset) }
  end

  # Source address of the per-anchor winner. The window-local flat index
  # (min_index / max_index) decomposes into per-axis window coordinates; the
  # source coordinate on each axis is anchor + offset + window-coordinate (the
  # offset is the range's begin for a padded margin, 0 for :truncate). A margin
  # winner (coordinate out of bounds) resolves per the boundary policy:
  # :nearest clamps to the edge source cell, :constant / :skip mask the result.
  def window_winner_addr (idx_op)
    mi = send(idx_op)                                    # window-local flat index
    n  = @source.shape
    wstride = Array.new(@sndim); acc = 1
    (@sndim - 1).downto(0) { |i| wstride[i] = acc; acc *= @widths[i] }
    sstride = Array.new(@sndim); acc = 1
    (@sndim - 1).downto(0) { |i| sstride[i] = acc; acc *= n[i] }
    lo = (@bounds == :truncate) ? @origins : @ranges.map(&:begin)
    addr = CArray.int64(*@shape); addr[] = 0
    oob  = CArray.boolean(*@shape); oob[] = 0
    (0...@sndim).each do |i|
      w_i    = (mi.int64 / wstride[i]) % @widths[i]       # window coordinate on axis i
      tshape = Array.new(@sndim, 1); tshape[i] = @shape[i]
      o_i    = CArray.int64(@shape[i]).seq!.reshape(*tshape)   # anchor ramp (broadcasts)
      coord  = o_i + lo[i] + w_i
      if @bounds == :nearest
        coord[coord < 0] = 0
        coord[coord >= n[i]] = n[i] - 1                   # replicate the nearest edge cell
      else
        oob = oob | (coord < 0) | (coord >= n[i])         # margin winner -> no source cell
      end
      addr = addr + coord * sstride[i]
    end
    addr[oob] = UNDEF unless @bounds == :nearest
    addr[mi.is_masked.eq(1)] = UNDEF if mi.has_mask?
    addr
  end

  public

  # @overload count(v = <none>)
  #   Rolling count over the window.  No argument counts present (non-masked)
  #   cells (the effective tap count, which drops near a :skip edge);
  #   `count(UNDEF)` counts masked cells; `count(v)` counts cells equal to `v`.
  #   @return [CArray]
  def count (*args)
    return count_not_masked if args.empty?
    # The sliding_windows view is a CAStride, so its #count is not shadowed;
    # dispatch CArray#count explicitly anyway, matching the family regularity.
    CArray.instance_method(:count).bind_call(sliding_view, *args, axis: @window_axes)
  end

  # @overload count_not_masked
  #   Rolling count of present (non-masked) cells -- the denominator of a
  #   renormalizing convolution.
  #   @return [CArray]
  def count_not_masked
    sliding_view.count_not_masked(axis: @window_axes)
  end

  # @overload count_masked
  #   Rolling count of masked cells.
  #   @return [CArray]
  def count_masked
    sliding_view.count_masked(axis: @window_axes)
  end

  # @overload elements
  #   Window cell count (structural, mask-independent): the constant window
  #   size `Π w_i`, shaped like the output.
  #   @return [CArray]
  def elements
    sz = @widths.inject(1) { |p, w| p * w }
    # count_not_masked gives the correct output shape (and is not shadowed);
    # overwrite with the constant window size.
    out = sliding_view.count_not_masked(axis: @window_axes)
    out[] = sz
    out
  end

  # ---- correlate / convolve ---------------------------------------------
  #
  # A windowed weighted sum: `out[i] = Σ_j window[i][j] · kernel[j]`.  The
  # engine computes cross-correlation (kernel not flipped); convolution flips
  # the kernel (one line).  Both are exposed under their literal names because
  # the flip convention splits by domain (signal processing flips, image / DL
  # does not).  For these, the constant margin default is 0.0 (the value a tap
  # reaching outside the source contributes); override with a :constant fill.

  # @overload correlate(kernel, min_count: nil, fill_value: nil)
  #   Rolling cross-correlation `out[i] = Σ_j a[i+j]·k[j]` (kernel not
  #   flipped).  `kernel` has the shape of one window (`w_1 × ... × w_n`).
  #   @param kernel [CArray] weights shaped like a single window.
  #   @return [CArray]
  def correlate (kernel, min_count: nil, fill_value: nil)
    unless kernel.shape == @widths
      raise ArgumentError,
            "correlate: kernel shape #{kernel.shape.inspect} != " \
            "window shape #{@widths.inspect}"
    end
    sv = sliding_view
    # Explicit broadcast of the kernel over the anchor axes: reshape to
    # 1 on every anchor axis, kernel width on every window axis (CArray forbids
    # implicit cross-ndim broadcast, so the shape is made explicit).
    kshape = ([1] * @sndim) + @widths
    # The product routes operand promotion through the single-source binop
    # coercion (result_type), so a float kernel over an int source promotes to
    # float instead of truncating the weights. Do not coerce the kernel here.
    prod   = sv * kernel.reshape(*kshape)
    kw = {}
    kw[:min_count]  = min_count  unless min_count.nil?
    kw[:fill_value] = fill_value unless fill_value.nil?
    prod.sum(axis: @window_axes, **kw)
  end

  # @overload convolve(kernel, min_count: nil, fill_value: nil)
  #   Rolling convolution `out[i] = Σ_j a[i-j]·k[j]` (true convolution: the
  #   kernel is flipped on every window axis).  Equals {#correlate} for a
  #   symmetric kernel.
  #   @param kernel [CArray] weights shaped like a single window.
  #   @return [CArray]
  def convolve (kernel, min_count: nil, fill_value: nil)
    correlate(reverse_all_axes(kernel), min_count: min_count, fill_value: fill_value)
  end

  private

  # Reverse a kernel on every axis (`CArray#reverse` flips all axes at once).
  def reverse_all_axes (kernel)
    kernel.reverse
  end

  public

  # ---- order statistics (median / percentile / quantile) ----------------
  #
  # Core per-axis order statistics take a single axis and do not accept a
  # masked input, so the window mode is dispatched:
  #
  #   single window axis + unmasked margin -> `sliding_view.op(axis: window_axis)`
  #   multi window axes + unmasked margin  -> materialize the windows, flatten
  #                                           the window axes into one, single-
  #                                           axis core order-stat
  #   :skip (UNDEF margin)                 -> raise (core has no masked per-axis
  #                                           order-stat); guide to :nearest /
  #                                           :truncate
  #
  # When core gains masked per-axis order statistics (a tracked refactor), the
  # :skip guard can be dropped and :skip served directly.

  # @overload median
  #   Rolling median.  Requires an unmasked margin (`bounds: :nearest` or
  #   `:truncate`); with the default `:skip` it raises.
  #   @return [CArray]
  def median
    order_stat { |view, axis| view.median(axis: axis) }
  end

  # @overload percentile(*pers)
  #   Rolling percentile(s).  One argument returns one CArray, several return
  #   an array of CArrays (as `CArray#percentile`).  Requires an unmasked
  #   margin.
  #   @return [CArray, Array<CArray>]
  def percentile (*pers)
    order_stat { |view, axis| view.percentile(*pers, axis: axis) }
  end

  # @overload quantile
  #   Rolling five-number summary `[min, Q1, median, Q3, max]` (five CArrays),
  #   as `CArray#quantile`.  Requires an unmasked margin.
  #   @return [Array<CArray>]
  def quantile
    order_stat { |view, axis| view.quantile(axis: axis) }
  end

  private

  # Drive an order statistic (yielded as `block.call(view, axis)`) through the
  # single-axis / multi-axis / :skip-reject dispatch above.
  def order_stat
    if @bounds == :skip
      raise ArgumentError,
            "windowed order statistics need an unmasked margin; " \
            "use bounds: :nearest (edge-extend) or bounds: :truncate (valid). " \
            "For an UNDEF-margin median use reduce { |w| w.median } (slower)."
    end
    sv = sliding_view
    if @window_axes.size == 1
      yield sv, @window_axes[0]
    else
      # Materialize the overlapping windows, flatten the window axes into one,
      # and run a single-axis core order-stat (vectorized; peak O(N·Πw)).
      mat   = sv.copy
      wsize = @widths.inject(1) { |p, w| p * w }
      flat  = mat.reshape(*(@shape + [wsize]))
      yield flat, @sndim              # the flattened window axis
    end
  end

  public

  # ---- weighted (wsum / wmean) ------------------------------------------

  # @overload wsum(weights)
  #   Rolling weighted sum, `weights` shaped like a single window.
  #   @return [CArray]
  def wsum (weights)
    weighted(weights) { |sv, w, axis| sv.wsum(w, axis: axis) }
  end

  # @overload wmean(weights)
  #   Rolling weighted mean, `weights` shaped like a single window.
  #   @return [CArray]
  def wmean (weights)
    weighted(weights) { |sv, w, axis| sv.wmean(w, axis: axis) }
  end

  private

  def weighted (weights)
    unless weights.shape == @widths
      raise ArgumentError,
            "wsum/wmean: weights shape #{weights.shape.inspect} != " \
            "window shape #{@widths.inspect}"
    end
    sv = sliding_view
    # Explicit broadcast of the per-window weights over the anchor axes, then
    # grow to the full view shape (core wsum / wmean take a per-cell weight
    # array shaped like the source, not the reduced-axis vector).
    wshape = ([1] * @sndim) + @widths
    wfull  = weights.reshape(*wshape).broadcast_to(*sv.shape)
    yield sv, wfull, @window_axes
  end

  public

  # ---- generic iteration (escape hatch, slow) ---------------------------
  #
  # `each` yields every window (a per-window materialize -- slow, but the
  # receptacle for statistics not in the named surface).  `reduce` folds each
  # window to one value (a custom rolling reduction), producing a reference-
  # shaped output.  `map` is defined only to raise NotImplementedError with an
  # explanation: overlapping windows make an element-wise scatter-back
  # ill-defined.

  # @overload each { |window| ... }
  #   Yields each anchor's window as a CArray.  Without a block, returns an
  #   Enumerator.  Per-window materialize, slow; use a named reduction or
  #   {#convolve} for speed.
  #   @yieldparam window [CArray]
  #   @return [Enumerator, self]
  def each
    return to_enum(:each) unless block_given?
    sv   = sliding_view
    nils = Array.new(@sndim, nil)      # full window on the trailing axes
    each_anchor_index { |idx| yield sv[*idx, *nils] }
    self
  end

  # @overload reduce { |window| ... }
  #   Custom rolling reduction: the block receives each window (a CArray) and
  #   returns one value per anchor.  The escape hatch for statistics not in the
  #   named surface.
  #   @yieldparam window [CArray]
  #   @return [CArray] reference-shaped (or shrunk, for :truncate)
  # @overload reduce(init) { |acc, elem| ... }
  #   Per-window fiber fold: each window's cells are folded element by element
  #   starting from `init`.
  #   @param init [Object] initial accumulator.
  #   @return [CArray]
  def reduce (*args, data_type: nil, &blk)
    raise LocalJumpError, "no block given (yield)" unless blk
    dt   = data_type || CA_OBJECT
    out  = CArray.new(dt, @shape)
    sv   = sliding_view
    nils = Array.new(@sndim, nil)      # full window on the trailing axes
    if args.empty?
      each_anchor_index { |idx| out[*idx] = blk.call(sv[*idx, *nils]) }
    else
      init = args[0]
      each_anchor_index do |idx|
        acc = init
        sv[*idx, *nils].each { |e| acc = blk.call(acc, e) }
        out[*idx] = acc
      end
    end
    out
  end

  # @overload map
  #   Not supported for a window iterator: overlapping windows share cells, so
  #   an element-wise transform has no well-defined scatter-back.  Raises
  #   NotImplementedError; use {#reduce} for a custom per-window fold.
  #   @raise [NotImplementedError]
  def map (*)
    raise NotImplementedError,
          "#{self.class} has no map: overlapping windows share cells, so an " \
          "element-wise scatter-back is ill-defined; use reduce for a custom " \
          "per-window fold."
  end

  # @overload sort_addr
  #   Not supported for a window iterator: a window's boundary cells are padding
  #   with no source address, and overlapping windows share cells, so a
  #   per-window sort returning source flat addresses is ill-defined.  Raises
  #   NotImplementedError.  (min_addr / max_addr are fine: the single winning
  #   cell of a window is a real source cell.)
  #   @raise [NotImplementedError]
  def sort_addr (*)
    raise NotImplementedError,
          "#{self.class} has no sort_addr: padded boundary cells have no " \
          "source address and overlapping windows share cells, so a per-window " \
          "sort of source addresses is ill-defined."
  end

  # @overload cumsum
  # @overload cumprod
  # @overload cummax
  # @overload cummin
  # @overload cumcount
  #   Not supported for a window iterator: a segment scan writes a per-cell
  #   running statistic, which is single-valued only when each cell belongs to
  #   exactly one piece.  Overlapping windows put a cell in many windows, so
  #   there is no single running value.  Raises NotImplementedError, exactly as
  #   {#map} / {#sort_addr} do (min / max reductions stay available: a single
  #   winner is well-defined).
  #   @raise [NotImplementedError]
  [:cumsum, :cumprod, :cummax, :cummin, :cumcount].each do |op|
    define_method(op) do |*, **|
      raise NotImplementedError,
            "#{self.class} has no #{op}: a segment scan needs each cell to " \
            "belong to exactly one piece, but overlapping windows share cells, " \
            "so a per-cell running value is ill-defined; use reduce for a " \
            "custom per-window fold."
    end
  end

  private

  # Yield every anchor index (the output iteration space) as an index Array of
  # length `@ndim` (the anchor axes only; callers append the window nils).
  def each_anchor_index
    CArray.each_index(*@shape) do |*idx|
      yield idx
    end
  end
end


class CArray
  # @overload windows(*ranges, bounds: :skip, fill_value: nil)
  #   Returns a {CAWindowIterator} rolling a per-axis offset window over
  #   `self`.  Each `ranges[i]` is a `lo..hi` offset span (`a.windows(-1..1)`
  #   is a centred width-3 window); `bounds:` selects the margin policy.  With
  #   no ranges (`a.windows(a.window(...))` passing a CAWindow view) the
  #   geometry is read from the view for backward compatibility.
  #   @param ranges [Array<Range>] per-axis offset ranges.
  #   @param bounds [Symbol] `:skip` / `:nearest` / `:truncate`.
  #   @param fill_value [Object, nil] constant margin value.
  #   @return [CAWindowIterator]
  def windows (*ranges, bounds: :skip, fill_value: nil)
    if ranges.size == 1 && ranges[0].is_a?(CArray) && ranges[0].obj_type == CA_OBJ_WINDOW
      return CAWindowIterator.new(ranges[0])
    end
    CAWindowIterator.new(self, *ranges, bounds: bounds, fill_value: fill_value)
  end
end

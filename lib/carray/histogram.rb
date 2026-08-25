# ----------------------------------------------------------------------------
#
#  `CArray::Histogram` + `CArray#histogram1d` / `#histogram2d` / `#histogram`.
#
#  A single class handles M=1, 2, ..., general M-D. The 1-D entry point
#  (`data.histogram1d`) reshapes the input to add a trailing channel axis of
#  length 1, then dispatches into the same Histogram path; the returned
#  object is a Histogram instance with M=1.
#
#  ## Concepts / vocabulary
#
#  ### Histogram dimensionality
#
#  * **M** — the histogram's dimensionality (= number of edges arrays = length
#    of the channel axis in input data). M=1 for `histogram1d`, M=2 for
#    `histogram2d`, M>=1 for general `histogram`.
#
#  ### Input layout
#
#  Data passed to the entry methods has shape:
#
#      fiber_shape  +  (A,)  +  (M,)
#         ^             ^         ^
#         |             |         channel axis (= M coordinate dims per sample)
#         |             sample axis (= A independent samples per fiber)
#         leading fiber axes (= per-fiber histogram is computed)
#
#  For `histogram1d` (M=1), the trailing `(M,)` axis may be omitted (= raw
#  `fiber_shape + (A,)` is accepted directly; the entry method reshapes).
#
#  * **fiber_shape** — the leading axes of the input.  Each fiber position
#    gets its own independent histogram.  shape `()` (= no fiber axes) means
#    "one global histogram over all samples".
#  * **sample axis** — the axis along which independent samples are drawn.
#    Locked at construction (= the entry method's `axis:` kwarg fixes it).
#  * **channel axis** — the trailing axis of length M carrying the M coordinate
#    dimensions of each sample.  For M=1 it is length 1 (= degenerate).
#
#  ### Bin structure
#
#  * **edges** — N+1 boundary values defining N bins per dimension.  Edges
#    must be sorted ascending.  bin k spans `[edges[k], edges[k+1])` (left-
#    closed, right-open).  See `include_max:` for the upper-edge variant.
#  * **bin** — half-open interval between two consecutive edges.  Bin index
#    k in 0..N-1.
#  * **N** (= n_list[k]) — number of bins along dimension k (= edges.size - 1).
#  * **midpoints** — bin center points: `(edges[0..-2] + edges[1..-1]) / 2`,
#    shape (N,).  Returned per-dim (single CArray for M=1, Array of M for M>=2).
#
#  ### Counts storage (= extended counts model)
#
#  Internal storage is a single CArray of shape:
#
#      fiber_shape  +  (n_0 + 2, n_1 + 2, ..., n_{M-1} + 2)
#
#  Each bin dimension is "extended" by 2 (= +1 cell on each side for under /
#  over).  All accumulation lands in this one buffer; outlier counters are
#  views (= no separate allocation).
#
#  * **full_counts** — the extended storage, shape includes outlier cells.
#  * **counts** — CABlock inner view: shape fiber + (n_0, ..., n_{M-1}), the
#    in-range bins only.  Zero-copy view of `full_counts`.
#  * **under(axis: k)** — count of samples whose dim-k coordinate fell below
#    `edges[k][0]`.  Other bin axes are marginalised (= summed over all
#    positions including their outliers).  shape = fiber_shape.
#  * **over(axis: k)** — symmetric upper outlier marginal.
#  * **outlier_total** — count of samples that fell outside on *any* axis
#    (= `total - counts.sum`).  shape = fiber_shape.
#  * **total** — count of all samples seen (including outliers).
#    shape = fiber_shape.
#
#  Per-dim marginals may "double-count" samples that fall out on multiple
#  axes (= a sample that's under on dim 0 AND over on dim 1 appears in both
#  `under(axis: 0)` and `over(axis: 1)`).  This is the intended marginal
#  reading; for exact non-overlapping breakdown, slice `full_counts`
#  directly.
#
#  ### Bin closure (`include_max:`)
#
#  By default, all bins are left-closed right-open: `[edges[k], edges[k+1])`.
#  A sample exactly at `edges[-1]` (= the upper boundary) falls into the over
#  counter, not bin N-1.  For bounded physical ranges (humidity 0-100%,
#  probability, angles mod 360°), opt in with `include_max:`:
#
#      h = data.histogram1d(edges: linspace(0, 100, 21), include_max: true)
#      # v == 100.0 now lands in bin 19 (= [95, 100]), not over.
#
#  Per-dim Array of booleans is accepted for joint histograms (= mark each
#  dim independently as bounded vs unbounded).
#
#  ### Weighted accumulation
#
#  Pass `weights: w` to `histogram1d` / etc., or to `add(chunk, weights: w)`.
#  Each sample contributes `w[i]` instead of 1 to its target cell.
#
#  * **weights.shape** = chunk.shape minus the channel axis (= fiber + (A,)).
#  * **dtype** is locked at construction (= the entry method's `weights:` kwarg
#    fixes weighted vs unweighted; subsequent adds must match).  Counts dtype:
#    int64 unweighted, float64 weighted.  Weighted counts are always float64:
#    the fused scatter kernel requires float64 weights, so integer weights are
#    taken as float64 (= integer weighted counts are not supported).
#
#  ### Streaming via `add`
#
#  The instance returned by the entry methods is a live accumulator; further
#  data can be added via `acc.add(chunk, weights: ...)`.  Shape contract:
#  the chunk's fiber_shape must match, sample axis length is free.  Empty
#  accumulator bootstrap: pass zero-length sample axis to the entry method
#  (e.g. `CArray.float64(K, L, 0).histogram1d(edges: e)`).
#
#  ### Mask handling
#
#  Input data with a CArray mask: masked samples are skipped (= not counted
#  in any cell, including outliers).  NaN inputs are treated the same way
#  (= masked via `mask_invalid`).  Per-sample mask is the union over all
#  channels (= a sample with even one masked channel is dropped entirely).
#
#  ### Composition
#
#  `h1 + h2` returns a new Histogram with cells summed elementwise.  Both
#  operands must agree on edges / fiber_shape / include_max / weighted dtype
#  (= the structure-level semantic guard); cells themselves are just
#  integer / float tallies.  See the `+` method.
#
# ----------------------------------------------------------------------------

class CArray

  # Binned counts over one or more continuous variables, of any
  # dimensionality M.  Built by `CArray#histogram1d` / `#histogram2d` /
  # `#histogram` rather than constructed directly; the 1-D entry point is the
  # same class with M = 1.
  #
  # For discrete integer labels (value == bin index, no edges) use
  # {BincountND} instead.
  class Histogram

    # @overload initialize(edges:, fiber_shape: [], include_max: false, weights_dtype: nil)
    #   Allocates a new histogram accumulator.
    #   @param edges [Array<CArray, Array<Numeric>>] one edges array
    #     per histogram dimension; each must be 1-D sorted ascending
    #     with at least 2 values.
    #   @param fiber_shape [Array<Integer>] shape of the leading
    #     (non-sample, non-channel) axes.
    #   @param include_max [Boolean, Array<Boolean>] whether values
    #     equal to the last edge fold into the last bin; a scalar
    #     broadcasts across dimensions.
    #   @param weights_dtype [Symbol, nil] `data_type` of the
    #     accumulator when weighted; `nil` for a count-only
    #     accumulator (int64 counts).
    #   @return [Histogram]
    def initialize (edges:, fiber_shape: [], include_max: false, weights_dtype: nil)
      @edges_list = edges.map { |e| CArray.wrap_readonly(e, :float64) }
      raise ArgumentError, "edges must be a non-empty list" if @edges_list.empty?
      @edges_list.each_with_index do |e, k|
        raise ArgumentError, "edges[#{k}] must be 1-D" unless e.ndim == 1
        raise ArgumentError, "edges[#{k}] needs at least 2 values" if e.elements < 2
      end
      @m = @edges_list.size                     # histogram dimensionality (= channel axis length)
      @n_list = @edges_list.map { |e| e.elements - 1 }   # per-dim bin count
      @fiber_shape = fiber_shape.map(&:to_i).freeze
      @include_max = case include_max
                     when Array
                       raise ArgumentError, "include_max length mismatch" unless include_max.size == @m
                       include_max.map { |v| !!v }
                     else
                       [!!include_max] * @m
                     end
      @weighted = !weights_dtype.nil?
      @counts_dtype = @weighted ? weights_dtype : :int64
      ext_dims = @n_list.map { |n| n + 2 }
      ext_shape = @fiber_shape + ext_dims
      @full_counts = CArray.public_send(@counts_dtype, *ext_shape).fill(0)
      @sample_axis  = nil
      @channel_axis = nil
    end
    private_class_method :new

    attr_reader :edges_list, :fiber_shape, :include_max, :n_list, :full_counts, :m

    # @overload edges
    #   Returns the bin edges: a single CArray when the accumulator
    #   is 1-D (M == 1), an Array of CArrays otherwise.
    #   @return [CArray, Array<CArray>]
    def edges
      @m == 1 ? @edges_list[0] : @edges_list
    end

    # @overload counts
    #   Returns the in-range counts view with shape
    #   `fiber_shape + (n1, n2, ..., nM)`, excluding under- and
    #   over-flow bins.
    #   @return [CArray]
    def counts
      idx = [nil] * @fiber_shape.size + [1..-2] * @m
      @full_counts[*idx]
    end

    # @overload under(axis: nil)
    #   Returns the underflow marginal along the given bin `axis`,
    #   shape `fiber_shape`. For 1-D accumulators `axis` may be
    #   omitted; for joint histograms it must be specified.
    #   @param axis [Integer, nil] bin dimension to marginalise.
    #   @return [CArray]
    #   @raise [ArgumentError] when `axis` is required but omitted.
    def under (axis: nil)
      raise ArgumentError, "axis: keyword required (M=#{@m})" if axis.nil? && @m > 1
      ax = axis.nil? ? 0 : CArray.normalize_axis(axis, @m, "under")
      outlier_marginal(ax, 0)
    end

    # @overload over(axis: nil)
    #   Returns the overflow marginal along the given bin `axis`,
    #   shape `fiber_shape`. Same `axis` convention as {#under}.
    #   @param axis [Integer, nil] bin dimension to marginalise.
    #   @return [CArray]
    #   @raise [ArgumentError] when `axis` is required but omitted.
    def over (axis: nil)
      raise ArgumentError, "axis: keyword required (M=#{@m})" if axis.nil? && @m > 1
      ax = axis.nil? ? 0 : CArray.normalize_axis(axis, @m, "over")
      outlier_marginal(ax, -1)
    end

    # @overload midpoints
    #   Returns the midpoint of each in-range bin. Polymorphic like
    #   {#edges}: a single CArray for M == 1, an Array of CArrays
    #   otherwise.
    #   @return [CArray, Array<CArray>]
    def midpoints
      arr = @edges_list.map { |e| (e[0..-2] + e[1..-1]) / 2.0 }
      @m == 1 ? arr[0] : arr
    end

    # @overload total
    #   Returns the per-fiber sample total, including outliers, with
    #   shape `fiber_shape` (or a scalar when `fiber_shape` is
    #   empty).
    #   @return [CArray]
    def total
      sum_along_bin_axes(@full_counts)
    end

    # @overload outlier_total
    #   Returns the per-fiber count of samples that fell outside
    #   every in-range bin.
    #   @return [CArray]
    def outlier_total
      sum_along_bin_axes(@full_counts) - sum_along_bin_axes(counts)
    end

    # @overload add(chunk, axis: nil, weights: nil)
    #   Accumulates `chunk` into `self`. On the first call the
    #   sample and channel axes are locked; subsequent calls must
    #   supply the same axis pair. When the accumulator is
    #   weighted, `weights` are required with a shape equal to
    #   `chunk.shape` minus the channel axis.
    #   @param chunk [CArray] sample values with shape
    #     `fiber_shape + (A, M)` (channel axis size must equal `m`).
    #   @param axis [Array(Integer, Integer), Integer, nil]
    #     `[sample, channel]` axis pair; a bare Integer is treated
    #     as the sample axis for 1-D accumulators.
    #   @param weights [CArray, nil] optional per-sample weights.
    #   @return [self]
    #   @raise [ArgumentError] on shape / axis / weighted-state
    #     mismatch.
    def add (chunk, axis: nil, weights: nil)
      chunk = CArray.wrap_readonly(chunk, :float64)

      # For M=1, accept chunks without the trailing channel axis (= the 1-D
      # user convention from `histogram1d`).  Auto-reshape adds a length-1
      # axis at the end; scalar `axis:` is interpreted as the sample axis in
      # the unwrapped layout.
      if @m == 1 && chunk.ndim == @fiber_shape.size + 1
        chunk = chunk.reshape(*(chunk.shape + [1]))
        if axis.is_a?(Integer)
          # axis was given in the unwrapped (pre-reshape) layout: normalize
          # against ndim-1 (= the unwrapped ndim) then pair with the new
          # trailing channel position.
          ax = CArray.normalize_axis(axis, chunk.ndim - 1, "add axis")
          axis = [ax, chunk.ndim - 1]
        end
      end

      # --- normalize axis: into [sample, channel] pair -----------------
      ax = axis || [-2, -1]
      ax = [ax] if ax.is_a?(Integer)
      raise ArgumentError, "axis must be [sample, channel]" unless ax.is_a?(Array) && ax.size == 2
      sample_ax  = CArray.normalize_axis(ax[0], chunk.ndim, "sample axis")
      channel_ax = CArray.normalize_axis(ax[1], chunk.ndim, "channel axis")
      raise ArgumentError, "same axis used twice" if sample_ax == channel_ax

      # --- lock axes on first add, otherwise verify against locked -----
      if @sample_axis.nil?
        @sample_axis = sample_ax
        @channel_axis = channel_ax
      elsif @sample_axis != sample_ax || @channel_axis != channel_ax
        raise ArgumentError,
              "axis mismatch (locked at [#{@sample_axis}, #{@channel_axis}], got [#{sample_ax}, #{channel_ax}])"
      end

      # --- validate chunk shape against (fiber_shape, M) ---------------
      expected_ndim = @fiber_shape.size + 2
      unless chunk.ndim == expected_ndim
        raise ArgumentError,
              "chunk.ndim=#{chunk.ndim} expected #{expected_ndim} " \
              "(fiber #{@fiber_shape.inspect} + sample + channel)"
      end
      unless chunk.shape[channel_ax] == @m
        raise ArgumentError,
              "channel axis length #{chunk.shape[channel_ax]} != M=#{@m}"
      end
      chunk_fiber = chunk.shape.dup
      [sample_ax, channel_ax].sort.reverse.each { |p| chunk_fiber.delete_at(p) }
      unless chunk_fiber == @fiber_shape
        raise ArgumentError,
              "fiber shape mismatch: chunk yields #{chunk_fiber.inspect}, expected #{@fiber_shape.inspect}"
      end

      sample_count = chunk.shape[sample_ax]
      return self if sample_count == 0

      if weights
        raise ArgumentError, "weights given but accumulator is unweighted" unless @weighted
        weights = CArray.wrap_readonly(weights, @counts_dtype)
        expected_w_shape = chunk.shape.dup
        expected_w_shape.delete_at(channel_ax)
        unless weights.shape == expected_w_shape
          raise ArgumentError,
                "weights shape #{weights.shape.inspect} expected #{expected_w_shape.inspect} " \
                "(chunk minus channel axis at #{channel_ax})"
        end
      elsif @weighted
        raise ArgumentError, "weights required (accumulator is weighted)"
      end

      # --- fused scatter kernel (stage 2) ------------------------------
      # Bin all M channels per sample and scatter directly into @full_counts
      # with NO intermediate index arrays (peak memory O(1), not O(M * A) for
      # A samples).
      # self is transposed to [fiber..., sample, channel] (a view; the kernel
      # iterator delivers it strided, no materialise).  Weights, if present,
      # are transposed to [fiber..., sample] and delivered by a second
      # iterator in lockstep (both views, no materialise).
      fiber_axes = (0...chunk.ndim).to_a - [sample_ax, channel_ax]
      tchunk = chunk.transpose(*(fiber_axes + [sample_ax, channel_ax]))

      tweights = nil
      if weights
        # weights axes = chunk axes with channel removed: an index above
        # channel_ax shifts down by 1.
        shift = ->(p) { p < channel_ax ? p : p - 1 }
        tweights = weights.transpose(*(fiber_axes.map(&shift) + [shift.call(sample_ax)]))
      end

      tchunk.send(:histogram_scatter_ki, @full_counts, @edges_list, @include_max, tweights)

      self
    end

    # @overload +(other)
    #   Returns a new Histogram whose counts are the element-wise
    #   sum of `self` and `other`. Both operands must share edges,
    #   `fiber_shape`, `include_max`, and weighted/unweighted state.
    #   @param other [Histogram] compatible accumulator.
    #   @return [Histogram]
    #   @raise [ArgumentError] when the structure does not match.
    def + (other)
      # --- semantic guards: structure must match exactly ---------------
      raise ArgumentError, "type mismatch" unless other.is_a?(Histogram)
      raise ArgumentError, "M mismatch" unless @m == other.m
      @edges_list.each_with_index do |e, k|
        raise ArgumentError, "edges[#{k}] mismatch" unless e == other.edges_list[k]
      end
      raise ArgumentError, "fiber_shape mismatch" unless @fiber_shape == other.fiber_shape
      raise ArgumentError, "include_max mismatch (semantic guard)" unless @include_max == other.include_max
      raise ArgumentError, "weighted/unweighted mismatch" unless @weighted == other.weighted?

      result = self.class.send(:new,
                               edges: @edges_list,
                               fiber_shape: @fiber_shape,
                               include_max: @include_max,
                               weights_dtype: @weighted ? @counts_dtype : nil)
      rf = result.instance_variable_get(:@full_counts)
      rf[] = @full_counts + other.full_counts
      result.instance_variable_set(:@sample_axis, @sample_axis)
      result.instance_variable_set(:@channel_axis, @channel_axis)
      result
    end

    protected

    # Exposed to sibling instances only (= `+` reads the other operand's
    # weighted state for the semantic guard).  protected, not public: this is
    # internal accumulator state, not part of the user-facing surface.
    def weighted?
      @weighted
    end

    private

    # arr.shape = fiber_shape + (last M bin axes).
    # Reduce along the last M axes, returns shape fiber_shape (or scalar).
    #
    # `accumulate` preserves dtype (= int64 stays int64, float64 stays float64),
    # unlike `sum` which always lifts to float64.  Caveat: int64 overflows at
    # ~9.2e18 (silent wrap); weighted float64 loses precision past 2^53 but
    # does not overflow.  Realistic histograms do not hit these limits.
    def sum_along_bin_axes (arr)
      out = arr
      @m.times { out = out.accumulate(axis: out.ndim - 1) }
      out
    end

    # axis k of the bin dims (= which channel's outlier to look at).
    # offset = 0 (under) or -1 (over).  Other bin axes are marginalised away
    # (= including their outlier positions).
    def outlier_marginal (axis, offset)
      base = [nil] * @fiber_shape.size
      bin_idx = (0...@m).map { |k|
        if k == axis
          offset == 0 ? 0 : @n_list[k] + 1
        else
          nil
        end
      }
      slice = @full_counts[*(base + bin_idx)]
      remaining = @m - 1
      remaining.times { slice = slice.accumulate(axis: slice.ndim - 1) }
      slice
    end

  end

end


class CArray

  # @overload histogram1d(edges:, axis: -1, include_max: false, weights: nil)
  #   Returns a 1-D {Histogram} built from `self` with shape
  #   `fiber_shape + (A,)`, where `A` is the sample axis of length
  #   picked by `axis`.
  #   @param edges [CArray, Array<Numeric>] 1-D ascending bin edges.
  #   @param axis [Integer] sample axis.
  #   @param include_max [Boolean] fold last-edge equality into the
  #     last bin.
  #   @param weights [CArray, nil] optional per-sample weights.
  #   @return [Histogram] 1-D accumulator (`m == 1`).
  def histogram1d (edges:, axis: -1, include_max: false, weights: nil)
    ax = normalize_axis(axis, "histogram1d")

    new_shape = shape + [1]
    arr_with_channel = reshape(*new_shape)
    # `include_max` passes straight through: the Histogram constructor
    # normalizes a scalar bool to per-dim, and raises on a wrong-length Array
    # (= same path as histogram2d, no M=1 special-casing here).
    arr_with_channel.histogram(edges: [edges],
                               axis: [ax, new_shape.size - 1],
                               include_max: include_max,
                               weights: weights)
  end

  # @overload histogram2d(edges:, axis: [-2, -1], include_max: false, weights: nil)
  #   Returns a 2-D joint {Histogram} built from `self` with shape
  #   `fiber_shape + (A, 2)`.
  #   @param edges [Array<CArray, Array<Numeric>>] two edges arrays.
  #   @param axis [Array(Integer, Integer)] `[sample, channel]`
  #     axis pair.
  #   @param include_max [Boolean, Array<Boolean>] fold-max flag,
  #     per dimension.
  #   @param weights [CArray, nil] optional per-sample weights.
  #   @return [Histogram] 2-D accumulator (`m == 2`).
  #   @raise [ArgumentError] when `edges` is not a length-2 Array.
  def histogram2d (edges:, axis: [-2, -1], include_max: false, weights: nil)
    raise ArgumentError, "edges must be a list of 2" unless edges.is_a?(Array) && edges.size == 2
    histogram(edges: edges, axis: axis, include_max: include_max, weights: weights)
  end

  # @overload histogram(edges:, axis: [-2, -1], include_max: false, weights: nil)
  #   Returns an M-D joint {Histogram} built from `self` with shape
  #   `fiber_shape + (A, M)`, where `M == edges.size`.
  #   @param edges [Array<CArray, Array<Numeric>>] one edges array
  #     per dimension.
  #   @param axis [Array(Integer, Integer)] `[sample, channel]`
  #     axis pair.
  #   @param include_max [Boolean, Array<Boolean>] fold-max flag,
  #     per dimension.
  #   @param weights [CArray, nil] optional per-sample weights.
  #   @return [Histogram]
  #   @raise [ArgumentError] when `edges` is not an Array.
  def histogram (edges:, axis: [-2, -1], include_max: false, weights: nil)
    raise ArgumentError, "edges must be an Array of edges arrays" unless edges.is_a?(Array)
    arr = self
    sample_ax  = normalize_axis(axis[0], "histogram sample axis")
    channel_ax = normalize_axis(axis[1], "histogram channel axis")
    fiber_shape = arr.shape.dup
    [sample_ax, channel_ax].sort.reverse.each { |p| fiber_shape.delete_at(p) }

    # Weighted counts are float64-only (the fused scatter kernel requires
    # float64 weights and float64 counts), so the dtype is fixed here rather
    # than derived from the weights' own dtype.
    weights_dtype = (:float64 if weights)

    h = Histogram.send(:new,
                      edges: edges,
                      fiber_shape: fiber_shape,
                      include_max: include_max,
                      weights_dtype: weights_dtype)
    h.add(arr, axis: axis, weights: weights)
    h
  end
end

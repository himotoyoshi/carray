# ----------------------------------------------------------------------------
#
#  carray/bincount_nd.rb
#
#  N-dimensional discrete joint counting — `CArray::BincountND` +
#  `CArray#bincount_nd`.  The discrete sibling of `CArray#histogram`:
#  integer labels are counted directly (value == bin index, no edges).
#
#  Use this for the *discrete* joint distribution of M integer variables.
#  For a plain 1-D discrete count use the dedicated `CArray#bincount`; for
#  *continuous* data use `CArray#histogram` (edges-based binning).
#
#  ## Surface (mirrors histogram, edges -> lengths)
#
#      data.bincount_nd(lengths: [L0, L1, ...], axis: [-2, -1], weights: w)
#
#  Input layout is the same as histogram: fiber_shape + (A,) + (M,), where
#  the trailing length-M channel axis carries the M integer coordinates of
#  each sample, and the sample axis (A) is reduced.
#
#  ## Bin model (= why outlier is upper-only)
#
#  Histogram's edges define *both* a lower (edges[0]) and an upper
#  (edges[-1]) boundary, hence under + over.  A discrete count has a
#  structural lower bound of 0 (labels index from 0); `length` L is the
#  upper cut.  So the only outlier direction is the upper one:
#
#      value v in 0..L-1  -> cell v
#      value v >= L       -> upper overflow cell (index L)
#      value v < 0        -> ArgumentError (not a valid discrete label)
#
#  Storage is therefore extended by +1 per dimension (one overflow cell on
#  top), unlike histogram's +2.
#
#      full_counts shape = fiber_shape + (L_0 + 1, ..., L_{M-1} + 1)
#      counts            = full_counts[..., 0...L_0, ..., 0...L_{M-1}]
#      overflow(axis: k) = samples whose dim-k label was >= L_k (marginal)
#
#  Weighted accumulation, streaming `add`, `+` composition and mask handling
#  all follow histogram: a sample is dropped iff any of its channels is masked
#  (union), and a fully-masked chunk is a no-op.  Labels are integer-only, so
#  label NaN cannot occur (float label arrays are rejected); weight NaN is
#  skipped like histogram.
#
#  NOTE (implementation): a layout-dependent hybrid, gate-benched
#  (devel/bench_bincount_nd_gate.rb):
#    - FLAT (no fiber): Ruby `ravel + bincount`.  The discrete "binning" is a
#      cheap, vectorisable ravel, so the separate vectorised ravel + the tuned
#      `bincount` kernel beats fusing it into a scalar scatter loop.
#    - FIBER: a dedicated C kernel `bincount_nd_count_ki` (ext/carray_histogram.c)
#      counts each fiber into its own L1-resident counts slice in one pass.
#      The Ruby path is slower for fibers (one giant cache-cold bincount,
#      or a per-fiber Ruby loop whose iteration overhead eats the locality);
#      the C kernel reads labels in their NATIVE int type (no int64 coercion),
#      giving O(1) peak.
#  Unlike histogram (where the float binning made a fully-fused kernel win
#  across the board), discrete binning only justifies C for the fiber case.
#
# ----------------------------------------------------------------------------

class CArray

  # Joint counts of M discrete integer variables — the discrete sibling of
  # {Histogram}, where a value is its own bin index and there are no edges.
  # Built by `CArray#bincount_nd` rather than constructed directly.
  #
  # For a plain 1-D discrete count use `CArray#bincount`; for continuous data
  # use `CArray#histogram`.
  class BincountND

    # @overload initialize(lengths:, fiber_shape: [], weights_dtype: nil)
    #   Allocates a new N-D discrete bincount accumulator.
    #   @param lengths [Array<Integer>] per-dimension label ranges;
    #     each must be `>= 1`.
    #   @param fiber_shape [Array<Integer>] shape of the leading
    #     axes.
    #   @param weights_dtype [Symbol, nil] `data_type` for weighted
    #     accumulators; `nil` for pure counts (int64).
    #   @return [BincountND]
    def initialize (lengths:, fiber_shape: [], weights_dtype: nil)
      @lengths = lengths.map(&:to_i)
      raise ArgumentError, "lengths must be a non-empty list" if @lengths.empty?
      @lengths.each_with_index do |l, k|
        raise ArgumentError, "lengths[#{k}] must be >= 1" if l < 1
      end
      @m = @lengths.size
      @fiber_shape = fiber_shape.map(&:to_i).freeze
      @weighted = !weights_dtype.nil?
      @counts_dtype = @weighted ? weights_dtype : :int64
      ext_dims = @lengths.map { |l| l + 1 }       # +1: upper overflow cell
      ext_shape = @fiber_shape + ext_dims
      @full_counts = CArray.public_send(@counts_dtype, *ext_shape).fill(0)
      @sample_axis  = nil
      @channel_axis = nil
    end
    private_class_method :new

    attr_reader :lengths, :fiber_shape, :full_counts, :m

    # @overload counts
    #   Returns the in-range counts view with shape
    #   `fiber_shape + (L_0, ..., L_{M-1})`, excluding the upper
    #   overflow cell.
    #   @return [CArray]
    def counts
      idx = [nil] * @fiber_shape.size + @lengths.map { |l| 0...l }
      @full_counts[*idx]
    end

    # Upper-overflow marginal on dim `axis` (= samples whose dim-axis label
    # was >= length[axis]); other dims marginalised.  shape = fiber_shape.
    # For M=1, axis: may be omitted.
    # @overload overflow(axis: nil)
    #   Returns the upper-overflow marginal on dimension `axis`
    #   (samples whose dim-axis label was `>= lengths[axis]`);
    #   other dimensions are marginalised. For 1-D accumulators
    #   `axis` may be omitted.
    #   @param axis [Integer, nil] dimension to marginalise.
    #   @return [CArray]
    #   @raise [ArgumentError] when `axis` is required but omitted.
    def overflow (axis: nil)
      raise ArgumentError, "axis: keyword required (M=#{@m})" if axis.nil? && @m > 1
      ax = axis.nil? ? 0 : CArray.normalize_axis(axis, @m, "overflow")
      base = [nil] * @fiber_shape.size
      bin_idx = (0...@m).map { |k| k == ax ? @lengths[k] : nil }   # overflow cell on ax
      slice = @full_counts[*(base + bin_idx)]
      (@m - 1).times { slice = slice.accumulate(axis: slice.ndim - 1) }
      slice
    end

    # @overload total
    #   Returns the per-fiber sample total (in-range plus overflow)
    #   with shape `fiber_shape`.
    #   @return [CArray]
    def total
      sum_along_bin_axes(@full_counts)
    end

    # @overload overflow_total
    #   Returns the per-fiber count of samples that overflowed on
    #   any dimension.
    #   @return [CArray]
    def overflow_total
      sum_along_bin_axes(@full_counts) - sum_along_bin_axes(counts)
    end

    # @overload add(chunk, axis: nil, weights: nil)
    #   Accumulates `chunk` (per-sample discrete labels) into `self`.
    #   Locks the sample/channel axes on the first call. Labels must
    #   be non-negative; labels `>= lengths[k]` fold into the upper
    #   overflow cell of dim `k`.
    #   @param chunk [CArray] integer labels with shape
    #     `fiber_shape + (A, M)`.
    #   @param axis [Array(Integer, Integer), Integer, nil]
    #     `[sample, channel]` axis pair.
    #   @param weights [CArray, nil] per-sample weights (required
    #     iff weighted accumulator).
    #   @return [self]
    #   @raise [ArgumentError] on shape / axis / label / weighted
    #     mismatch.
    def add (chunk, axis: nil, weights: nil)
      # Keep the labels in their native integer type (no int64 coercion): an
      # int32 label array stays int32 through the ravel, and `bincount` picks
      # a uint32 output when the table fits.  Forcing int64 would materialise
      # a cast of the whole chunk.
      chunk = CArray.wrap_readonly(chunk)

      # M=1 convenience: accept chunks without the trailing channel axis.
      if @m == 1 && chunk.ndim == @fiber_shape.size + 1
        chunk = chunk.reshape(*(chunk.shape + [1]))
        if axis.is_a?(Integer)
          ax = CArray.normalize_axis(axis, chunk.ndim - 1, "add axis")
          axis = [ax, chunk.ndim - 1]
        end
      end

      ax = axis || [-2, -1]
      ax = [ax] if ax.is_a?(Integer)
      raise ArgumentError, "axis must be [sample, channel]" unless ax.is_a?(Array) && ax.size == 2
      sample_ax  = CArray.normalize_axis(ax[0], chunk.ndim, "sample axis")
      channel_ax = CArray.normalize_axis(ax[1], chunk.ndim, "channel axis")
      raise ArgumentError, "same axis used twice" if sample_ax == channel_ax

      if @sample_axis.nil?
        @sample_axis = sample_ax
        @channel_axis = channel_ax
      elsif @sample_axis != sample_ax || @channel_axis != channel_ax
        raise ArgumentError,
              "axis mismatch (locked at [#{@sample_axis}, #{@channel_axis}], got [#{sample_ax}, #{channel_ax}])"
      end

      expected_ndim = @fiber_shape.size + 2
      unless chunk.ndim == expected_ndim
        raise ArgumentError,
              "chunk.ndim=#{chunk.ndim} expected #{expected_ndim} " \
              "(fiber #{@fiber_shape.inspect} + sample + channel)"
      end
      unless chunk.shape[channel_ax] == @m
        raise ArgumentError, "channel axis length #{chunk.shape[channel_ax]} != M=#{@m}"
      end
      chunk_fiber = chunk.shape.dup
      [sample_ax, channel_ax].sort.reverse.each { |p| chunk_fiber.delete_at(p) }
      unless chunk_fiber == @fiber_shape
        raise ArgumentError,
              "fiber shape mismatch: chunk yields #{chunk_fiber.inspect}, expected #{@fiber_shape.inspect}"
      end

      return self if chunk.shape[sample_ax] == 0

      if weights
        raise ArgumentError, "weights given but accumulator is unweighted" unless @weighted
        weights = CArray.wrap_readonly(weights, @counts_dtype)
        expected_w_shape = chunk.shape.dup
        expected_w_shape.delete_at(channel_ax)
        unless weights.shape == expected_w_shape
          raise ArgumentError,
                "weights shape #{weights.shape.inspect} expected #{expected_w_shape.inspect}"
        end
      elsif @weighted
        raise ArgumentError, "weights required (accumulator is weighted)"
      end

      # --- ravel + bincount --------------------------------------------
      # Each label is its own bin: clamp to the upper overflow cell and ravel
      # the M channels into one flat index, then let the dedicated bincount
      # kernel scatter.  Discrete "binning" is a cheap, vectorisable ravel, so
      # this beats a hand-fused scalar kernel (bench: a fused C kernel was
      # ~4.4 vs ~1.6 ns/sample).  With fibers we loop one small ravel+bincount
      # per fiber so each fiber's counts slice stays L1-resident, rather than
      # one giant bincount over the whole F*total_ext table (which is cache-
      # cold and ~1.7x slower).  See devel/bench_bincount_nd_gate.rb.
      ext_sizes   = @lengths.map { |l| l + 1 }      # +1: upper overflow cell
      strides_ext = ext_sizes.each_with_index.map { |_, k| ext_sizes[(k + 1)..].inject(1, :*) }
      total_ext   = ext_sizes.inject(:*)
      widen       = total_ext > 0x7fffffff          # int64 flat for big joint tables

      # canonical [fiber..., sample, channel] view (channel last); weights to
      # [fiber..., sample].  Skip the transpose when the layout is already
      # canonical (the usual case) — a transpose view would force `reshape`
      # below to materialise a full copy.
      fiber_axes = (0...chunk.ndim).to_a - [sample_ax, channel_ax]
      perm   = fiber_axes + [sample_ax, channel_ax]
      tchunk = perm == (0...chunk.ndim).to_a ? chunk : chunk.transpose(*perm)
      tweights = nil
      if weights
        shift  = ->(p) { p < channel_ax ? p : p - 1 }
        w_perm = fiber_axes.map(&shift) + [shift.call(sample_ax)]
        tweights = w_perm == (0...weights.ndim).to_a ? weights : weights.transpose(*w_perm)
      end

      # One pass for the negative-label check (masked-aware).  `min` returns
      # UNDEF when every sample is masked: that is a well-defined no-op (all
      # samples dropped -> counts unchanged), so bail before the label-range
      # checks below (`chunk.min` / `b.max` would otherwise hit UNDEF and the
      # FLAT path arithmetic would raise on it).
      mn = chunk.min
      return self if mn == UNDEF
      raise ArgumentError, "bincount_nd: negative label" if mn < 0

      if @fiber_shape.empty?
        # Flat: the ravel is cheap + vectorisable, so the separate
        # vectorised ravel + tuned `bincount` beats any fused kernel.
        # Clamp a channel only when it actually overflows (decided once).
        ravel = nil
        (0...@m).each do |k|
          b = tchunk[nil, k]
          b = b.clip(0, @lengths[k]) if b.max > @lengths[k] - 1
          b = b.int64 if widen
          term = strides_ext[k] == 1 ? b : b * strides_ext[k]
          ravel = ravel.nil? ? term : ravel + term
        end
        chunk_counts = ravel.bincount(weights: tweights, length: total_ext)
        @full_counts[] = @full_counts + chunk_counts.reshape(*@full_counts.shape)
      else
        # Fiber: a dedicated C kernel counts each fiber into its own
        # L1-resident counts slice in one pass (no per-fiber Ruby loop, no
        # giant cache-cold bincount, no int coercion).  Clamp is inline in C.
        tchunk.send(:bincount_nd_count_ki, @full_counts, tweights)
      end
      self
    end

    # @overload +(other)
    #   Returns a new BincountND whose counts are the element-wise
    #   sum of `self` and `other`. Both operands must share
    #   `lengths`, `fiber_shape`, and weighted state.
    #   @param other [BincountND] compatible accumulator.
    #   @return [BincountND]
    #   @raise [ArgumentError] when structure does not match.
    def + (other)
      raise ArgumentError, "type mismatch" unless other.is_a?(BincountND)
      raise ArgumentError, "M mismatch" unless @m == other.m
      raise ArgumentError, "lengths mismatch" unless @lengths == other.lengths
      raise ArgumentError, "fiber_shape mismatch" unless @fiber_shape == other.fiber_shape
      raise ArgumentError, "weighted/unweighted mismatch" unless @weighted == other.weighted?

      result = self.class.send(:new,
                               lengths: @lengths,
                               fiber_shape: @fiber_shape,
                               weights_dtype: @weighted ? @counts_dtype : nil)
      rf = result.instance_variable_get(:@full_counts)
      rf[] = @full_counts + other.full_counts
      result.instance_variable_set(:@sample_axis, @sample_axis)
      result.instance_variable_set(:@channel_axis, @channel_axis)
      result
    end

    protected

    def weighted?
      @weighted
    end

    private

    def sum_along_bin_axes (arr)
      out = arr
      @m.times { out = out.accumulate(axis: out.ndim - 1) }
      out
    end

  end

end


class CArray

  # @overload bincount_nd(lengths:, axis: [-2, -1], weights: nil)
  #   Returns a discrete N-D joint {BincountND} count of `self` with
  #   shape `fiber_shape + (A, M)`. Each of the `M` channels is an
  #   integer label in `0..lengths[k]-1`; labels `>= lengths[k]`
  #   fold into the upper overflow cell, negative labels raise.
  #   @param lengths [Array<Integer>] per-dimension extents.
  #   @param axis [Array(Integer, Integer)] `[sample, channel]`
  #     axis pair.
  #   @param weights [CArray, nil] optional per-sample weights.
  #   @return [BincountND]
  def bincount_nd (lengths:, axis: [-2, -1], weights: nil)
    raise ArgumentError, "lengths must be an Array of per-dim extents" unless lengths.is_a?(Array)
    sample_ax  = normalize_axis(axis[0], "bincount_nd sample axis")
    channel_ax = normalize_axis(axis[1], "bincount_nd channel axis")
    fiber_shape = shape.dup
    [sample_ax, channel_ax].sort.reverse.each { |p| fiber_shape.delete_at(p) }

    # Weighted counts are float64-only (the FLAT bincount coerces weights to the
    # counts dtype and the FIBER kernel requires float64 weights/counts), so the
    # dtype is fixed here rather than derived from the weights' own dtype.
    weights_dtype = (:float64 if weights)

    h = BincountND.send(:new,
                        lengths: lengths,
                        fiber_shape: fiber_shape,
                        weights_dtype: weights_dtype)
    h.add(self, axis: axis, weights: weights)
    h
  end
end

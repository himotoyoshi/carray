class CArray

  # @overload bin(vmin, vmax, step = nil, bins: nil, lfill: nil, ufill: nil, include_max: true)
  #   Returns each element's bin index for equal-width, half-open bins
  #   over `[vmin, vmax]`. Bin `k` covers `[vmin + k*w, vmin + (k+1)*w)`
  #   where `w = (vmax - vmin) / n`. The number of bins is set either by
  #   `step` (positional; bin width, matching `snap`'s step) or by
  #   `bins:` (kwarg; count of bins, matching histogram convention);
  #   exactly one must be given.
  #
  #   Because `[vmin, vmax]` is a user-declared inclusive range, values
  #   exactly equal to `vmax` land in the last bin by default
  #   (`include_max: true`); this differs from `bin_to`, where the
  #   user-supplied edges are treated as-is (half-open, default `false`).
  #
  #   Out-of-range convention follows `bin_to` / `project`: `lfill` for
  #   below-range, `ufill` for above-range; `nil` on either side masks
  #   that side. NaN / masked input cells are always masked in the
  #   output, independently of `lfill` / `ufill`.
  #
  #   Use `snap(step, offset:)` when the desired output is the snapped
  #   value; use `bin_to(edges)` when the edges are non-uniform.
  #
  #   @param vmin [Numeric] range lower bound.
  #   @param vmax [Numeric] range upper bound; must be `>= vmin`.
  #   @param step [Numeric, nil] bin width. The number of bins is
  #     `((vmax - vmin) / step).round` (silent FP rounding, standard
  #     numeric convention).
  #   @param bins [Integer, nil] number of bins (alternative to `step`);
  #     must be `>= 1`.
  #   @param lfill [Integer, nil] fill for below-range cells.
  #   @param ufill [Integer, nil] fill for above-range cells.
  #   @param include_max [Boolean] fold values equal to `vmax` into the
  #     last bin instead of treating them as above-range.
  #   @return [CArray] `CA_INT64` bin indices in `[0, n-1]`, same
  #     shape as `self`.
  #   @raise [ArgumentError] when neither / both of `step` and `bins:`
  #     are given, `bins < 1`, or `vmin > vmax`.
  #   @example
  #     temp.bin(270, 300, 0.5)               # 60 uniform bins every 0.5 K
  #     temp.bin(0, 1, bins: 100)             # 100 equal-width bins over [0, 1]
  #     temp.bin(0, 9, 1, lfill: 0, ufill: 8) # clamp OOB to end bins
  def bin(vmin, vmax, step = nil, bins: nil, lfill: nil, ufill: nil, include_max: true)
    if step.nil? == bins.nil?
      raise ArgumentError, "bin: give exactly one of `step` or `bins:`"
    end
    raise ArgumentError, "bin: vmin > vmax" if vmin > vmax

    n = bins || ((vmax - vmin).to_f / step).round
    raise ArgumentError, "bin: n must be >= 1" if n < 1

    if vmin == vmax
      # Degenerate: zero interval → all cells fall on the single edge;
      # with include_max: true they land in bin 0.
      out = CArray.int64(*shape) { 0 }
      out.mask = self.mask.to_ca if self.has_mask?
      if self.float?
        inv = self.is_invalid
        if inv.count(true) > 0
          out.mask = out.has_mask? ? (out.mask | inv) : inv
        end
      end
      return out
    end

    # Delegate to `bin_to` with generated uniform edges — same kernel
    # (`histbin_ki`) as `histogram`, so semantics are identical.
    edges = CArray.float64(n + 1).span(vmin..vmax)
    bin_to(edges, lfill: lfill, ufill: ufill, include_max: include_max)
  end

  # @overload bin_to(edges, lfill: nil, ufill: nil, include_max: false)
  #   Returns each element's bin index against an explicit ascending
  #   `edges` array (non-uniform binning). Sibling of `bin` (uniform,
  #   range + step) and `snap_to` (nearest-value snap to the same shape
  #   of grid).
  #
  #   `edges` are `N+1` ascending boundaries defining `N` bins; bin
  #   `k` covers the half-open interval `[edges[k], edges[k+1])`.
  #   Out-of-range values follow the `bin` / `project` convention:
  #   a value below `edges[0]` becomes `lfill`, a value at or above
  #   `edges[-1]` becomes `ufill`; `nil` on either side masks that
  #   side. When `include_max` is true, a value exactly equal to
  #   `edges[-1]` lands in the last bin `N-1` instead of being
  #   treated as above-range. NaN or masked input cells are masked
  #   in the output, independently of `lfill` / `ufill`.
  #
  #   The inner binning kernel is shared with `histogram`, which counts
  #   how many values land in each bin.
  #
  #   @param edges [CArray, Array<Numeric>] 1-D ascending boundaries
  #     with at least 2 values.
  #   @param lfill [Integer, nil] fill for below-range cells; `nil`
  #     masks them.
  #   @param ufill [Integer, nil] fill for above-range cells; `nil`
  #     masks them.
  #   @param include_max [Boolean] fold values equal to `edges[-1]`
  #     into the last bin instead of treating them as above-range.
  #   @return [CArray] `CA_INT64` array with the same shape as `self`
  #     holding bin indices in `[0, N-1]` (or the fill values / mask
  #     for out-of-range and masked cells).
  #   @raise [ArgumentError] when `edges` is not 1-D or has fewer
  #     than 2 values.
  #   @example
  #     e = CA_FLOAT64([0, 1, 10, 100])
  #     v = CA_FLOAT64([0.5, 5.0, 50.0, -1.0, 200.0])
  #     v.bin_to(e)                  # => [0, 1, 2, UNDEF, UNDEF]
  #     v.bin_to(e, lfill: 0, ufill: 2)
  #                                  # => [0, 1, 2, 0, 2]
  def bin_to(edges, lfill: nil, ufill: nil, include_max: false)
    e = CArray.wrap_readonly(edges, :float64)
    raise ArgumentError, "bin_to: edges must be 1-D" unless e.ndim == 1
    raise ArgumentError, "bin_to: edges needs at least 2 values" if e.elements < 2
    n = e.elements - 1                                  # number of bins

    src = data_type == CA_FLOAT64 ? self : CArray.wrap_readonly(self, :float64)

    # histbin_ki returns the extended index (0 = under, 1..N = in-range bins,
    # N+1 = over; NaN / masked -> masked).  Shift to the in-range convention:
    # under -> -1, in-range -> 0..N-1, over -> N.
    out = src.send(:histbin_ki, e, include_max) - 1

    out[:eq, -1] = lfill.nil? ? UNDEF : lfill          # under
    out[:eq, n]  = ufill.nil? ? UNDEF : ufill          # over
    out
  end

end

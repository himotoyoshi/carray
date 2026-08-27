class CArray

  # @overload snap(step, offset: 0.0, direction: :round)
  #   Returns each element snapped to a point on the uniform grid
  #   `..., -step + offset, offset, step + offset, 2*step + offset, ...`.
  #   The rounding rule follows `direction:` (default `:round`,
  #   matching `CArray#round`; `:floor` snaps toward `-inf`, `:ceil`
  #   toward `+inf`).
  #
  #   The output has the same data type as `self` (integer input is coerced
  #   to float internally when `step` / `offset` are floats, following
  #   normal arithmetic promotion). NaN / Inf are preserved as a mask
  #   on the output; the rounding kernels map NaN to 0.0, which would
  #   silently land NaN cells on the grid, so NaN is detected
  #   explicitly on the scaled chain.
  #
  #   Use `snap_to(list)` when the target grid is non-uniform; use
  #   `bin(vmin, vmax, step)` when the desired output is a bin index.
  #
  #   @param step [Numeric] positive grid spacing.
  #   @param offset [Numeric] phase / origin of the grid; the grid
  #     always passes through `offset`.
  #   @param direction [:round, :floor, :ceil] rounding rule; `:round`
  #     picks the nearest grid point (ties half-away-from-zero),
  #     `:floor` picks the grid point at or below the value, `:ceil`
  #     picks the grid point at or above.
  #   @return [CArray] snapped values, same shape as `self`.
  #   @raise [ArgumentError] when `step <= 0` or `direction` is not one
  #     of the accepted symbols.
  #   @example
  #     temp.snap(0.5)                        # nearest 0.5 K grid point
  #     temp.snap(0.5, offset: 0.25)          # to 0.25, 0.75, 1.25, ... (bin centers)
  #     temp.snap(0.5, direction: :floor)     # bin lower edge
  #     temp.snap(0.5, direction: :ceil)      # bin upper edge
  def snap(step, offset: 0.0, direction: :round)
    raise ArgumentError, "snap: step must be > 0" unless step > 0
    unless [:round, :floor, :ceil].include?(direction)
      raise ArgumentError,
            "snap: direction must be :round / :floor / :ceil " \
            "(got #{direction.inspect})"
    end

    scaled = (self - offset) / step

    # Detect NaN / Inf before rounding (which maps NaN -> 0.0 silently).
    invalid_mask = scaled.float? ? scaled.is_invalid : nil

    out = scaled.send(direction) * step + offset

    if invalid_mask && invalid_mask.count(true) > 0
      out.mask = out.has_mask? ? (out.mask | invalid_mask) : invalid_mask
    end

    out
  end

  # @overload snap_to(list, lfill: :clamp, ufill: :clamp, direction: :round)
  #   Returns each element snapped to a value in `list` (non-uniform
  #   grid). The rounding rule follows `direction:` (default `:round`
  #   for nearest neighbour; `:floor` picks the list value at or below
  #   the sample, `:ceil` at or above), and delegates to
  #   `locate_nearest_addr(direction:)`.
  #
  #   `list` must be a 1-D ascending numeric CArray (or convertible via
  #   `CArray.wrap_readonly`). Out-of-range and NaN handling follows the
  #   same pattern as `bin_to`, but with an additional `:clamp`
  #   sentinel that snaps out-of-range cells to the nearest list end.
  #
  #   - `:clamp` (default) — below-range cells become `list[0]`,
  #     above-range cells become `list[-1]`.
  #   - `nil` — the side is masked in the output.
  #   - any other value — the side is filled with that value.
  #
  #   NaN / masked input cells are always masked in the output,
  #   regardless of `lfill` / `ufill`.
  #
  #   Use `snap(step, offset:)` when the target grid is uniform; use
  #   `bin_to(edges)` when the output is a bin index against half-open
  #   intervals rather than a nearest-value snap.
  #
  #   @param list [CArray, Array<Numeric>] 1-D ascending grid, at least
  #     one value.
  #   @param lfill [:clamp, nil, Numeric] handling for below-`list[0]`
  #     cells.
  #   @param ufill [:clamp, nil, Numeric] handling for above-`list[-1]`
  #     cells.
  #   @param direction [:round, :floor, :ceil] rounding rule; forwarded
  #     to `locate_nearest_addr`.
  #   @return [CArray] snapped values with `list`'s data_type, same
  #     shape as `self`.
  #   @raise [ArgumentError] when `list` is not 1-D or is empty, or
  #     `direction` is not one of the accepted symbols.
  #   @example
  #     temp.snap_to([270.0, 280.0, 290.0, 300.0])                   # clamp OOB
  #     temp.snap_to(grid, lfill: nil, ufill: nil)                   # mask OOB
  #     rain.snap_to([0.0, 1.0, 5.0, 20.0], direction: :floor)       # list value at or below
  def snap_to(list, lfill: :clamp, ufill: :clamp, direction: :round)
    ref = list.is_a?(CArray) ? list : CArray.wrap_readonly(list, self.data_type)
    raise ArgumentError, "snap_to: list must be 1-D" unless ref.ndim == 1
    n = ref.elements
    raise ArgumentError, "snap_to: list must have at least one value" if n < 1

    if n == 1
      # Degenerate: every finite cell snaps to the only value.
      out = CArray.new(ref.data_type, shape).fill(ref[0])
      out.mask = self.mask.to_ca if self.has_mask?
      if self.float?
        inv = self.is_invalid
        if inv.count(true) > 0
          out.mask = out.has_mask? ? (out.mask | inv) : inv
        end
      end
      return out
    end

    # `locate_nearest_addr` (via `linear_section`) accepts a 1-D `val` only;
    # flatten multi-D input and reshape the result back to preserve the
    # element-wise semantic on any shape.
    if ndim > 1
      return reshape(-1).snap_to(ref, lfill: lfill, ufill: ufill,
                                 direction: direction).reshape(*shape)
    end

    # locate_nearest_addr returns int64 indices; OOB (below / above / NaN)
    # cells come back masked. We split OOB into below / above with
    # explicit comparisons so the two sides can be filled independently.
    idx = self.locate_nearest_addr(ref, direction: direction)
    out = ref.project(idx)

    below = self.lt(ref[0])
    above = self.gt(ref[-1])

    case lfill
    when :clamp then out[below] = ref[0]
    when nil    then # leave masked (locate_nearest_addr already masked OOB)
    else             out[below] = lfill
    end

    case ufill
    when :clamp then out[above] = ref[-1]
    when nil    then # leave masked
    else             out[above] = ufill
    end

    # Propagate input mask (locate_nearest_addr / project do not forward
    # `self`'s mask on their own; a masked input cell must produce a
    # masked output cell regardless of the fill options above).
    if self.has_mask?
      m = self.mask.to_ca
      out.mask = out.has_mask? ? (out.mask | m) : m
    end

    out
  end

end

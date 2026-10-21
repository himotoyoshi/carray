# Mask gap-fill: the `method:` keyword on #unmask / #strip_mask.
#
# #unmask and #strip_mask clear a mask by *supplying values*.  The value
# source is either a constant (the existing positional argument) or a
# scan-method derived from neighbouring valid cells:
#
#   unmask(v)                    # in-place, constant fill (C primitive)
#   strip_mask(v)                # copy,     constant fill (C primitive)
#   unmask(method: :forward)     # in-place, carry last valid value  (hold)
#   strip_mask(method: :backward)# copy,     carry next valid value  (hold)
#   unmask(method: :linear)      # in-place, linear-by-index interpolation
#
# The constant path stays positional; the method path is keyword-only
# (a positional Symbol is already a valid constant fill, e.g.
# `strip_mask(:na)`).  Passing both raises ArgumentError.
#
# Design / rationale: devel/PROPOSAL_UNMASK_FILL_METHOD.md.  The forward
# hold is the C primitive #hold_forward; backward = flip -> forward -> flip,
# flatten = flatten -> hold -> reshape, and :linear composes
# linear_section / linear_fetch.  User-facing YARD docs live in
# yard-stubs/carray_mask.rb.
#
# A Face (CATime, CATimedelta, a categorical) rides both paths through its
# storage: hold copies bytes, so it never invents a value and needs nothing
# from the Face; :linear goes through the Face's own linear_fetch, so the
# filled values land on the array's unit.  In place, the write-back goes to
# the storage -- a bulk store into a Face's surface would try to cast the
# storage values to it (int64 ticks to fixlen, for a time array).

class CArray

  # Sentinel for "no positional fill value given" (distinct from any real
  # fill value, including nil / false / a Symbol).
  MASK_FILL_UNSET = ::Object.new
  Ractor.make_shareable(MASK_FILL_UNSET)
  private_constant :MASK_FILL_UNSET

  # unmask / strip_mask with method:, in front of the C constant-fill
  # primitives, which they reach with super.
  module GapFill
    def unmask (fill = MASK_FILL_UNSET, method: nil, axis: nil)
      if method
        unless fill.equal?(MASK_FILL_UNSET)
          raise ArgumentError,
                "unmask: pass either a constant fill value or method:, not both"
        end
        held = gap_fill(method, axis, "unmask")
        # Copy the filled values in place (a Face takes a Face of its own kind
        # as it is).
        value[] = held.value
        if held.has_mask?
          self.mask = held.mask              # residual leading/trailing mask
        else
          super()                   # fully filled: drop the mask
        end
        return self
      end
      fill.equal?(MASK_FILL_UNSET) ? super() : super(fill)
    end

    def strip_mask (fill = MASK_FILL_UNSET, method: nil, axis: nil)
      if method
        unless fill.equal?(MASK_FILL_UNSET)
          raise ArgumentError,
                "strip_mask: pass either a constant fill value or method:, not both"
        end
        return carry_attrs(gap_fill(method, axis, "strip_mask"))
      end
      if fill.equal?(MASK_FILL_UNSET)
        raise ArgumentError, "strip_mask: a fill value is required (or method:)"
      end
      carry_attrs(super(fill))
    end
  end
  prepend GapFill

  private

  # Dispatch a method-fill to a fresh array.  Residual (leading/trailing)
  # unfillable cells stay masked; a fully filled result carries no mask
  # (hold allocates the output mask only when a leading run goes UNDEF;
  # :linear masks only the exterior via mask_invalid).
  def gap_fill (method, axis, name)
    axis = normalize_axis(axis, name) unless axis.nil?
    case method
    when :forward, :ffill
      hold_along_axis(axis, false)
    when :backward, :bfill
      hold_along_axis(axis, true)
    when :linear
      gap_fill_linear(axis)
    else
      raise ArgumentError,
            "unmask/strip_mask: unknown method: #{method.inspect} " \
            "(:forward | :backward | :linear)"
    end
  end

  # Forward (backward = false) or backward (true) hold along `axis`, already
  # normalised by gap_fill (axis nil = flatten).  Backward reuses the forward primitive on the
  # reversed view; flatten flattens, holds axis 0, reshapes back.
  def hold_along_axis (axis, backward)
    if axis.nil?
      flat = flatten
      flat = flat.reverse if backward
      held = flat.send(:hold_forward, 0)
      held = held.reverse if backward
      held.reshape(*shape)
    else
      if backward
        flip(axis).send(:hold_forward, axis).flip(axis)
      else
        send(:hold_forward, axis)
      end
    end
  end

  # Linear-by-index gap fill: interpolate each masked cell from the two
  # bracketing valid cells, x = cell index along the axis.  Cells outside the
  # valid range (leading/trailing) stay masked.  A Face goes through its own
  # linear_fetch, which keeps its unit and rounds to its grid.  Defining one
  # is how a Face says it interpolates: without it, the core linear_fetch
  # reads the Face's storage and fails from inside.
  def gap_fill_linear (axis)
    if face?
      unless interpolable?
        raise ArgumentError,
              "unmask/strip_mask(method: :linear): #{self.class} does not " \
              "interpolate (it defines no linear_fetch of its own); " \
              "use method: :forward or :backward"
      end
    elsif ! numeric?
      raise ArgumentError,
            "unmask/strip_mask(method: :linear): numeric or time data_type " \
            "required (got #{data_type_name})"
    end
    if axis.nil?
      return linear_fill_fiber(flatten).reshape(*shape)
    end
    ax = axis
    # A fiber comes back in self's own type (a Face's linear_fetch has already
    # rounded to its grid), so the result assembles in that type and the
    # present cells are never carried through float64.
    out = face? ? template : value.copy
    each_fiber_key(ax) do |key|
      out[*key] = linear_fill_fiber(self[*key])
    end
    out
  end

  # Whether linear interpolation can fill this array: a numeric array, or a
  # Face that defines a linear_fetch of its own -- which is how a Face says it
  # interpolates (the core linear_fetch would read its storage).
  private def interpolable?
    face? ? self.class.instance_method(:linear_fetch).owner != CArray : numeric?   # type-label: asks what the Face can do, names nothing
  end

  # 1-D linear-by-index fill of a single (possibly masked) fiber.
  def linear_fill_fiber (vec)
    vec.send(:linear_fill_along, CArray.float64(vec.elements) { |i| i.to_f })
  end

  # Fill the masked cells of this 1-D array by linear interpolation against
  # the coordinate `x` (same length).  `x` need not be in order: the present
  # cells are read as one series in the order of their `x`, so a frame whose
  # index restarts for each station interpolates across the stations by
  # time (interpolate one station at a time to keep them apart).  Present
  # cells sharing an `x` keep their row order.  A cell whose `x` is masked,
  # NaN or infinite has no place on the line: it is not used and not filled.
  # The one rule both the core (x = cell position) and CAFrame (x = index)
  # use: present cells come back exactly as they are, in this array's own
  # type; a masked cell inside the span of the present ones takes the
  # interpolated value; one outside it stays masked.  Outside is where
  # linear_section answers NaN -- a property of x, not of the values, so a
  # NaN or Inf stored in a present cell is left alone.  A Face goes through
  # its own linear_fetch, which keeps its unit and rounds to its grid.
  def linear_fill_along (x)
    # A cell whose coordinate is masked, NaN or infinite has no place on the
    # line: it is no point to interpolate between, and is not filled.
    placed = x.is_not_masked
    placed &= x.is_finite if !x.face? && x.float?
    placed = placed.strip_mask(false)
    present = is_not_masked & placed
    # Fewer than two valid points -> nothing to interpolate between; leave
    # every masked cell masked.
    return copy if present.count(true) < 2
    grid  = x[present]
    order = nil
    if ( grid[1..-1] < grid[0..-2] ).any
      order = grid.sort_addr                  # stable: ties keep their row order
      grid  = grid[order]
    end
    addr = grid.linear_section(x)             # valid positions -> monotonic grid
    fill = (is_masked & placed & addr.is_finite).strip_mask(false)
    if face?
      # The Face's linear_fetch lands on its own grid; only the cells to fill
      # take it, so a present cell comes back as it is.
      known = self[present]
      known = known[order] if order
      out = copy
      out[fill] = known.linear_fetch(addr)[fill] if fill.any
      return out
    end
    v = value[present]
    v = v[order] if order
    # A complex value interpolates its real and imaginary parts.
    interp = v.complex? ? v.linear_fetch(addr) : v.float64.linear_fetch(addr)
    # An integer array takes the nearest integer, half away from zero (as a
    # time Face lands on its own grid), rounded before the store would cut
    # the fraction off.
    interp = interp.round if integer?
    # Built from the values alone, so a fully filled result carries no mask.
    out      = value.copy
    exterior = is_masked & fill.not
    out[fill] = interp[fill] if fill.any
    out[exterior] = UNDEF if exterior.any
    out
  end

  # Yield an index key (Array with `nil` at `axis`, integers elsewhere)
  # for every fiber along `axis`.  `self[*key]` is that fiber as a masked
  # 1-D view.
  def each_fiber_key (axis)
    outer = shape
    outer_dims = outer.each_index.reject { |k| k == axis }.map { |k| outer[k] }
    idx = Array.new(outer_dims.size, 0)
    total = outer_dims.inject(1, :*)
    total.times do
      key = idx.dup
      key.insert(axis, nil)
      yield key
      (outer_dims.size - 1).downto(0) do |k|
        idx[k] += 1
        break if idx[k] < outer_dims[k]
        idx[k] = 0
      end
    end
  end
  private :hold_along_axis, :gap_fill_linear, :linear_fill_fiber,
          :each_fiber_key

end

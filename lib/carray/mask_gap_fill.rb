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
# hold is the C primitive #__hold__; backward = flip -> forward -> flip,
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

  # Preserve the C constant-fill primitives under private names so the
  # Ruby wrappers can delegate the non-method path unchanged.
  alias __unmask_const__ unmask
  alias __strip_mask_const__ strip_mask
  private :__unmask_const__, :__strip_mask_const__

  # Sentinel for "no positional fill value given" (distinct from any real
  # fill value, including nil / false / a Symbol).
  MASK_FILL_UNSET = ::Object.new
  private_constant :MASK_FILL_UNSET

  def unmask (fill = MASK_FILL_UNSET, method: nil, axis: nil)
    if method
      unless fill.equal?(MASK_FILL_UNSET)
        raise ArgumentError,
              "unmask: pass either a constant fill value or method:, not both"
      end
      held = __gap_fill__(method, axis, "unmask")
      # Copy the filled values in place.  A Face writes through its storage: a
      # bulk store into its surface would try to cast the storage values to the
      # surface type (int64 ticks to fixlen, for a time array).
      if face?
        parent.value[] = held.parent.value
      else
        value[] = held.value
      end
      if held.has_mask?
        self.mask = held.mask              # residual leading/trailing mask
      else
        __unmask_const__                   # fully filled: drop the mask
      end
      return self
    end
    fill.equal?(MASK_FILL_UNSET) ? __unmask_const__ : __unmask_const__(fill)
  end

  def strip_mask (fill = MASK_FILL_UNSET, method: nil, axis: nil)
    if method
      unless fill.equal?(MASK_FILL_UNSET)
        raise ArgumentError,
              "strip_mask: pass either a constant fill value or method:, not both"
      end
      return __gap_fill__(method, axis, "strip_mask")
    end
    if fill.equal?(MASK_FILL_UNSET)
      raise ArgumentError, "strip_mask: a fill value is required (or method:)"
    end
    __strip_mask_const__(fill)
  end

  private

  # Dispatch a method-fill to a fresh array.  Residual (leading/trailing)
  # unfillable cells stay masked; a fully filled result carries no mask
  # (hold allocates the output mask only when a leading run goes UNDEF;
  # :linear masks only the exterior via mask_invalid).
  def __gap_fill__ (method, axis, name)
    axis = normalize_axis(axis, name) unless axis.nil?
    case method
    when :forward, :ffill
      __hold_axis__(axis, false)
    when :backward, :bfill
      __hold_axis__(axis, true)
    when :linear
      __gap_fill_linear__(axis)
    else
      raise ArgumentError,
            "unmask/strip_mask: unknown method: #{method.inspect} " \
            "(:forward | :backward | :linear)"
    end
  end

  # Forward (backward = false) or backward (true) hold along `axis`, already
  # normalised by __gap_fill__ (axis nil = flatten).  Backward reuses the forward primitive on the
  # reversed view; flatten flattens, holds axis 0, reshapes back.
  def __hold_axis__ (axis, backward)
    if axis.nil?
      flat = flatten
      flat = flat.reverse if backward
      held = flat.send(:__hold__, 0)
      held = held.reverse if backward
      held.reshape(*shape)
    else
      if backward
        flip(axis).send(:__hold__, axis).flip(axis)
      else
        send(:__hold__, axis)
      end
    end
  end

  # Linear-by-index gap fill: interpolate each masked cell from the two
  # bracketing valid cells, x = cell index along the axis.  Cells outside the
  # valid range (leading/trailing) stay masked.  A Face goes through its own
  # linear_fetch, which keeps its unit and rounds to its grid.  Defining one
  # is how a Face says it interpolates: without it, the core linear_fetch
  # reads the Face's storage and fails from inside.
  def __gap_fill_linear__ (axis)
    if face?
      unless self.class.instance_method(:linear_fetch).owner != CArray
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
      return __linear_fiber__(flatten).reshape(*shape)
    end
    ax = axis
    # A fiber comes back in self's own type (a Face's linear_fetch has already
    # rounded to its grid), so the result assembles in that type and the
    # present cells are never carried through float64.
    out  = face? ? template : value.copy
    sink = face? ? out.parent : out
    __each_fiber_key__(ax) do |key|
      fiber = __linear_fiber__(self[*key])
      sink[*key] = face? ? fiber.parent : fiber
    end
    out
  end

  # 1-D linear-by-index fill of a single (possibly masked) fiber.
  def __linear_fiber__ (vec)
    vec.send(:__linear_fill_along__, CArray.float64(vec.elements) { |i| i.to_f })
  end

  # Fill the masked cells of this 1-D array by linear interpolation against
  # the coordinate `x` (same length, ascending over the present cells).
  # The one rule both the core (x = cell position) and CAFrame (x = index)
  # use: present cells come back exactly as they are, in this array's own
  # type; a masked cell inside the span of the present ones takes the
  # interpolated value; one outside it stays masked.  Outside is where
  # linear_section answers NaN -- a property of x, not of the values, so a
  # NaN or Inf stored in a present cell is left alone.  A Face goes through
  # its own linear_fetch, which keeps its unit and rounds to its grid.
  def __linear_fill_along__ (x)
    present = is_not_masked
    # Fewer than two valid points -> nothing to interpolate between; leave
    # every masked cell masked.
    return copy if present.count(true) < 2
    addr = x[present].linear_section(x)       # valid positions -> monotonic grid
    if face?
      # The Face's linear_fetch already masks the exterior (out of range) and
      # lands on its own grid.
      return self[present].linear_fetch(addr)
    end
    interp = value.float64[present].linear_fetch(addr)
    # Built from the values alone, so a fully filled result carries no mask.
    out      = value.copy
    masked   = is_masked
    fill     = masked & addr.is_finite
    exterior = masked & fill.not
    out[fill] = interp[fill] if fill.any
    out[exterior] = UNDEF if exterior.any
    out
  end

  # Yield an index key (Array with `nil` at `axis`, integers elsewhere)
  # for every fiber along `axis`.  `self[*key]` is that fiber as a masked
  # 1-D view.
  def __each_fiber_key__ (axis)
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
  private :__hold_axis__, :__gap_fill_linear__, :__linear_fiber__,
          :__each_fiber_key__

end

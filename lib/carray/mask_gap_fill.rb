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
      held = __gap_fill__(method, axis)
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
      return __gap_fill__(method, axis)
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
  def __gap_fill__ (method, axis)
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

  # Forward (backward = false) or backward (true) hold along `axis`
  # (axis nil = flatten).  Backward reuses the forward primitive on the
  # reversed view; flatten flattens, holds axis 0, reshapes back.
  def __hold_axis__ (axis, backward)
    if axis.nil?
      flat = flatten
      flat = flat.reverse if backward
      held = flat.send(:__hold__, 0)
      held = held.reverse if backward
      held.reshape(*shape)
    else
      ax = axis < 0 ? axis + ndim : axis
      if backward
        flip(ax).send(:__hold__, ax).flip(ax)
      else
        send(:__hold__, ax)
      end
    end
  end

  # Linear-by-index gap fill: interpolate each masked cell from the two
  # bracketing valid cells, x = cell index along the axis.  Cells outside the
  # valid range (leading/trailing) stay masked.  A Face goes through its own
  # linear_fetch, which keeps its unit and rounds to its grid; whether that
  # means anything is the Face's call (an ORDERABLE numeric one answers, the
  # rest raise from there), so this gate only asks that it be one.
  def __gap_fill_linear__ (axis)
    unless numeric? || face?
      raise ArgumentError,
            "unmask/strip_mask(method: :linear): numeric or time data_type " \
            "required (got #{data_type_name})"
    end
    if axis.nil?
      return __linear_fiber__(flatten).reshape(*shape)
    end
    ax = axis < 0 ? axis + ndim : axis
    if ax < 0 || ax >= ndim
      raise ArgumentError, "axis #{axis} out of range for ndim #{ndim}"
    end
    # A Face assembles in storage space -- its linear_fetch has already rounded
    # to the grid, so there is nothing left to hold in float64.  A numeric
    # array assembles in float64 and casts back once at the end.
    out  = face? ? template : float64.copy
    sink = face? ? out.parent : out
    __each_fiber_key__(ax) do |key|
      fiber = __linear_fiber__(self[*key])
      sink[*key] = face? ? fiber.parent : fiber
    end
    face? ? out : out.to_type(data_type)
  end

  # 1-D linear-by-index fill of a single (possibly masked) fiber.  Present
  # cells reproduce exactly; interior masked cells interpolate; exterior
  # masked cells become UNDEF (linear_section returns NaN out of range,
  # mask_invalid marks it).  Returns the same kind as `vec`: a Face fiber
  # comes back as that Face, on its own unit.
  def __linear_fiber__ (vec)
    n = vec.elements
    present = vec.is_not_masked
    # Fewer than two valid points -> nothing to interpolate between; leave
    # every masked cell masked (the copy carries vec's mask).
    if present.count(true) < 2
      return vec.face? ? vec.copy : vec.float64.copy
    end
    pos  = CArray.float64(n) { |i| i.to_f }
    addr = pos[present].linear_section(pos)   # valid positions -> monotonic grid
    if vec.face?
      # The Face's linear_fetch already masks the exterior (out of range) and
      # lands on its own grid, so it needs no cast and no mask_invalid.
      return vec[present].linear_fetch(addr)
    end
    vval = vec.value.float64[present]         # valid values
    vval.linear_fetch(addr).to_type(vec.data_type).mask_invalid
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

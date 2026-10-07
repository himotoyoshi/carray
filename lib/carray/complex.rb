# Complex-component accessors (real / real= / imag / imag= / real? /
# is_real).  Loaded eagerly BEFORE carray/lazy.rb, because lazy.rb does
# `alias_method :__real_eager__, :real` (and the imag equivalent) at load
# time -- these defs must exist by then.

class CArray

  # complex number
  #
  # ---------------------------------------------------------------------------
  # DO NOT RETIRE real / real= / imag / imag= IN FAVOUR OF THE LAZY FRAMEWORK
  # ---------------------------------------------------------------------------
  #
  # A recurring temptation is to consider these methods redundant now that the
  # lazy substrate provides `c.lazy.real` / `c.lazy.imag` via CAMonOp chains
  # (cast_<float> for real; imag_i + cast_<float> for imag — see
  # lib/carray/lazy.rb).  They are NOT redundant.  The two paths are
  # **complementary** and serve different abstractions:
  #
  #   c.real        (here)          -> CAField:  mutable zero-copy view into
  #                                              the byte slot of complex
  #                                              storage.  Read AND write.
  #   c.lazy.real   (lazy.rb)       -> CAMonOp:  read-only lazy chain node
  #                                              for streaming consumption.
  #
  # The CAField path supports in-place mutation idioms that the lazy framework
  # cannot express:
  #
  #   c = CArray.cmplx128(10)
  #   c.real.seq!(1)        # write 1..10 into real slot, zero-copy
  #   c.imag.seq!(-1,-1)    # write -1..-10 into imag slot
  #   c.real = some_array   # bulk write into real slot
  #
  # These are used by spec/Features/feature_stat_spec.rb and by user code
  # patterns CArray's "byte-slot mutable view" capability is designed to
  # support (= writing to `.real` stores into the real part in place;
  # CAField makes it a zero-copy abstraction available across all
  # CAStride-based view algebra).
  #
  # Architecturally:
  #   - lib/carray/lazy.rb's `real`/`imag` overrides dispatch to CAMonOp
  #     when self is a lazy view, and fall through to the defs here for eager
  #     parents (via `alias_method :__real_eager__, :real` at load time).
  #     This file MUST be required before carray/lazy.rb (see carray.rb), and
  #     removing these defs would break that alias and the lazy.rb load.
  #
  #   - ext/ca_obj_stride.c recognises `CAField .real/.imag over complex`
  #     as a first-class byte-mismatched reinterpret pattern.  Architectural
  #     commitment is already written into the C layer.
  #
  # Outright deletion is a regression on a documented capability (the lazy
  # framework's read-only chain does not replace the CAField mutable view).
  # ---------------------------------------------------------------------------

  # Whether a view kept by {#real} / {#imag} was made for this array.
  # `dup` and `clone` copy instance variables, so a copy arrives holding the
  # original's view, whose parent is the original; the copy makes its own.
  def part_of_self? (view)
    view && view.parent.equal?(self)
  end
  private :part_of_self?

  # @overload real
  #   Returns the real part of `self` as a zero-copy view. For a
  #   complex array the view is a mutable {CAField} into the
  #   real-part slot; for a real numeric array it is a {CARefer}
  #   over `self`. Writing to the view updates `self` in place.
  #   @return [CArray]
  def real
    return @__real__ if part_of_self?(@__real__)
    view = if complex?
             case data_type
             when CA_CMPLX64  then field(0, CA_FLOAT32)
             when CA_CMPLX128 then field(0, CA_FLOAT64)
             end
           else
             self[]
           end
    frozen? ? view : (@__real__ = view)
  end

  # @overload real=(val)
  #   Sets the real-part slot to `val` via {#real}.
  #   @param val [CArray, Numeric] value to broadcast.
  #   @return [Object] `val`.
  def real= (val)
    real[] = val
  end

  # @overload imag
  #   Returns the imaginary part of `self`. For a complex array the
  #   result is a mutable {CAField} view of the imaginary slot;
  #   writing to it updates `self` in place. For an object array each
  #   cell's `imaginary`; for a real array a fresh independent CArray
  #   filled with 0. Masked cells stay masked.
  #   @return [CArray]
  def imag
    if object?
      return imag_i
    end
    if not complex?
      zero = template { 0 }
      zero[is_masked] = UNDEF if has_mask?
      return zero
    end
    return @__imag__ if part_of_self?(@__imag__)
    view = case data_type
           when CA_CMPLX64  then field(4, CA_FLOAT32)
           when CA_CMPLX128 then field(8, CA_FLOAT64)
           end
    frozen? ? view : (@__imag__ = view)
  end

  # @overload imag=(val)
  #   Sets the imaginary-part slot to `val` (complex arrays only).
  #   @param val [CArray, Numeric] value to broadcast.
  #   @return [Object] `val`.
  #   @raise [RuntimeError] when `self` is not a complex array.
  def imag= (val)
    if complex?
      imag[] = val
    else
      raise "not a complex array"
    end
  end

  # @overload real?
  #   Returns whether every element of `self` is real (imaginary
  #   part is zero for complex arrays; always `true` for real
  #   numeric arrays; `nil` for non-numeric arrays).
  #   @return [Boolean, nil]
  def real?
    if complex?
      imag.eq(0).all
    elsif numeric?
      true
    else
      nil
    end
  end

  # @overload is_real
  #   Returns an element-wise boolean CArray marking cells whose
  #   imaginary part is zero (all-true for real numeric arrays,
  #   `nil` for non-numeric arrays).
  #   @return [CArray, nil]
  def is_real
    if complex?
      imag.eq(0)
    elsif numeric?
      self.true
    else
      nil
    end
  end

end

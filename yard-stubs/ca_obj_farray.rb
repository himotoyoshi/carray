# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for CAFarray and CArray#farray defined in ext/ca_obj_farray.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

# Column-major (Fortran-order) view of a row-major parent.  Pure
# `CAStride` typedef: the parent's bytes are reread with dimension
# order reversed (`view.shape[k] == parent.shape[ndim-1-k]`).  No
# data is copied; writes go through to the parent.
class CAFarray < CAStride
end

# Mask companion of {CAFarray}.
class CAFarrayMask < CAFarray
end

class CArray
  # @!group Views

  # @overload farray
  #   Returns a {CAFarray} view of `self` that exposes the same memory
  #   in column-major (Fortran) order.  The shape is `self.shape`
  #   reversed; element `view[i_0, ..., i_{n-1}]` aliases parent
  #   element `self[i_{n-1}, ..., i_0]`.
  #
  #   Useful for interop with column-major consumers (LAPACK, Fortran
  #   libraries) without copying.
  #   @return [CAFarray]
  def farray; end

  # @!endgroup
end

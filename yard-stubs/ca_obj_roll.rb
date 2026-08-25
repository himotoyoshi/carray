# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for CARoll and CArray#roll defined in ext/ca_obj_roll.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

# Cyclic-shift view of the parent.  Same shape as the parent; each
# axis `k` is rotated by `shift[k]` cells (modulo `parent.dim[k]`).
# All parent cells alias through the view exactly once, so writes
# through the view reach the parent.
#
# `CARoll` is a `typedef` of {CATile}: the class hierarchy places it
# under {CATile}, and the operation table is a copy of `ca_tile_func`
# with the shift-specific slots overridden.
class CARoll < CATile
end

# Mask companion of {CARoll}.
class CARollMask < CARoll
end

class CArray
  # @!group Views

  # Returns a {CARoll} view of `self` cyclically shifted by
  # `shifts[k]` along each axis `k`.  Positive shifts move cell `i`
  # of the parent to position `i + shift`; negative shifts move it
  # the other way.  Each `shift[k]` is normalised into
  # `[0, self.dim[k])` before use, so any integer is accepted.
  #
  # Fewer args than `ndim` treats the missing axes as `shift = 0`.
  # More args than `ndim` raises `ArgumentError`.
  #
  # The in-place idiom is `ca[] = ca.roll(...)`; there is no `roll!`.
  # For a non-cyclic translation with a fill value use {#shift}.
  #
  # @overload roll(*shifts)
  #   @param shifts [Array<Integer>] one shift per axis; may be
  #     shorter than `ndim` (missing axes default to `0`).
  #   @return [CARoll]
  #   @raise [ArgumentError] when more than `ndim` shifts are given.
  #   @raise [IndexError] when any parent dimension is non-positive.
  def roll(*shifts); end

  # @!endgroup
end

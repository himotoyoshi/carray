# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for methods defined in ext/carray_lazy.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

# Zero-cost marker view that dispatches subsequent element-wise ops
# into the lazy CAMonOp / CABinOp tree instead of evaluating eagerly.
# Read-only; `.to_ca` materialises.
class CALazyMarker < CAView
end

class CArray
  # @!group Views
  # @overload lazy
  #   Returns a {CALazyMarker} view wrapping `self`.  Subsequent
  #   element-wise ops on the marker (`m.sqrt`, `m + 1`, ...) build
  #   a lazy expression tree; call `.to_ca` on the result to
  #   materialise.  The marker is transient — a Ruby reference can
  #   re-consume it (`m = a.lazy; m.sqrt + m.sin`) without side
  #   effects on `self`.
  #   @return [CALazyMarker]
  def lazy; end
  # @!endgroup
end

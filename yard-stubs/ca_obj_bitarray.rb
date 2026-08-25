# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for CABitarray and CArray#bitarray defined in ext/ca_obj_bitarray.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

# Per-bit expansion view of the parent.  Every parent cell is fanned
# out into `parent.bytes * 8` boolean cells along a trailing bit
# axis appended after the parent's own axes, so the view's shape is
# `[*parent.shape, parent.bytes * 8]` and its `data_type` is
# `:boolean`.
#
# On big-endian hosts the bit axis of a non-fixlen parent reflects
# network byte order (parent bytes are walked in reverse within each
# element); single-byte parents are linear on either endian.
class CABitarray < CAView
end

class CArray
  # @!group Views

  # Returns a {CABitarray} view of `self`, exposing every bit of
  # every parent cell as an individual boolean cell.  See
  # {CABitarray} for the axis layout and endian handling.
  #
  # Aliased as `bits`.
  #
  # @overload bitarray
  #   @return [CABitarray]
  #   @raise [CADataTypeError] when `self.data_type` is a complex or
  #     object type (bit-level access is not defined for those).
  def bitarray; end

  # Alias for {#bitarray}.
  #
  # @return [CABitarray]
  def bits; end

  # @!endgroup
end

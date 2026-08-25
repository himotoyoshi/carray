# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for CABitfield and CArray#bitfield defined in ext/ca_obj_bitfield.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

# Bit-field extraction view: each cell of `self` carries a contiguous
# bit field of the parent, exposed as an unsigned-integer (or boolean
# when the field is 1 bit wide) CArray of the same shape.  Writes
# through the view are read-modify-write against the parent — bits
# outside the field are preserved.
class CABitfield < CAView
end

class CArray
  # @!group Views

  # Returns a {CABitfield} view of `self`.  Each parent cell is
  # treated as a bag of bits; `range` selects a contiguous slice of
  # those bits, and the resulting view exposes that slice as a cell
  # of the returned array.
  #
  # `range` may be an integer (a single bit — the resulting view has
  # `data_type :boolean`) or a `Range` covering the bit positions.
  # The `data_type` of the view is chosen from the bit width:
  # 1 bit → `:boolean`, 2..8 → `:uint8`, 9..16 → `:uint16`,
  # 17..32 → `:uint32`, 33..64 → `:uint64`.
  #
  # `type` is accepted but currently ignored (the width-derived type
  # is always used).
  #
  # @overload bitfield(range, type = nil)
  #   @param range [Integer, Range] bit position (single bit) or bit
  #     range within one parent cell.
  #   @param type [Symbol, nil] reserved, currently ignored.
  #   @return [CABitfield]
  #   @raise [IndexError] when `range` extends past the parent's bit
  #     width, when the range has a step != 1, or when the bit length
  #     is outside `1..64`.
  #   @raise [ArgumentError] when the derived bit length exceeds the
  #     resolved data type.
  def bitfield(range, type = nil); end

  # @!endgroup
end

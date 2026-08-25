# Pack / unpack an integer CArray to and from a packed-bit byte string,
# +nb+ bits per element.

class CArray

  # @overload to_bit_string(nb)
  #   Returns a packed-bit byte string built from `self`, using `nb`
  #   bits per element.
  #   @param nb [Integer] bits per element.
  #   @return [String] byte string of length `ceil(nb * elements / 8)`.
  def to_bit_string (nb)
    hex = CArray.uint8(((nb*elements)/8.0).ceil)
    hex.bits[nil].paste([0], self.bits[false,[(nb-1)..0]].flatten)
    hex.bits[] = hex.bits[nil,[-1..0]]
    return hex.to_s
  end

  # @overload from_bit_string(bstr, nb)
  #   Sets `self` by unpacking `bstr` as a packed-bit byte string
  #   with `nb` bits per element.
  #   @param bstr [String] packed byte string.
  #   @param nb [Integer] bits per element.
  #   @return [self]
  def from_bit_string (bstr, nb)
    hex = CArray.uint8(bstr.length).load_binary(bstr)
    hex.bits[] = hex.bits[nil,[-1..0]]
    bits = hex.bits.flatten
    self.bits[false,[(nb-1)..0]][nil].paste([0], bits)
    return self
  end

  # @overload from_bit_string(bstr, nb, data_type = CA_INT32, dim = nil)
  #   Returns a new CArray built by unpacking `bstr` as a packed-bit
  #   byte string with `nb` bits per element.
  #   @param bstr [String] packed byte string.
  #   @param nb [Integer] bits per element.
  #   @param data_type [Symbol, Integer] result `data_type`.
  #   @param dim [Array<Integer>, nil] result shape; when `nil` the
  #     length is `floor(bstr.length * 8 / nb)`.
  #   @return [CArray]
  def self.from_bit_string (bstr, nb, data_type=CA_INT32, dim=nil)
    if dim
      obj = CArray.new(data_type, dim)
    else
      dim0 = ((bstr.length*8)/nb.to_f).floor
      obj = CArray.new(data_type, [dim0])
    end
    obj.from_bit_string(bstr, nb)
    return obj
  end

  # @overload pack_bits
  #   Packs a 1-D boolean / 0-1 uint8 CArray of length `n` into a uint8
  #   CArray of `ceil(n / 8)` bytes, LSB-first within each byte. Exact
  #   inverse of the `.bitarray` view's unpack direction: for any packed
  #   uint8 array `p`, `p.bitarray.reshape(-1)[0...p.elements * 8].pack_bits`
  #   round-trips to `p`. Tail bits of the last byte (when `n` is not a
  #   multiple of 8) are zero-filled. The byte order matches the packed-bit
  #   convention used by Apache Arrow validity bitmaps and PEP 3118 `?` /
  #   `_Bool` at the bit level.
  #   @return [CArray] uint8 CArray of shape `[ceil(n / 8)]`.
  #   @raise [ArgumentError] when the receiver is not 1-D or its
  #     `data_type` is not one of `CA_BOOLEAN` / `CA_UINT8` / `CA_INT8`.
  def pack_bits
    unless data_type == CA_BOOLEAN || data_type == CA_UINT8 || data_type == CA_INT8
      raise ArgumentError,
        "pack_bits: expected CA_BOOLEAN / CA_UINT8 / CA_INT8 (got #{data_type_name})"
    end
    raise ArgumentError, "pack_bits: 1-D CArray expected (got rank #{rank})" unless rank == 1
    n = elements
    n_bytes = (n + 7) / 8
    packed = CArray.uint8(n_bytes) { 0 }
    return packed if n == 0
    packed.bitarray.reshape(-1)[0..n-1] = self
    packed
  end

  # @overload validity_bits
  #   Returns a packed uint8 CArray where bit `i` is 1 iff cell `i` of the
  #   receiver is *not* masked (LSB-first, length `ceil(elements / 8)`).
  #   Returns `nil` when the receiver has no mask; consumers such as Arrow
  #   treat a missing bitmap as "all valid", so `nil` is the correct
  #   omission-signalling value.
  #   Equivalent to `is_not_masked.pack_bits` when a mask is present.
  #   @return [CArray, nil] uint8 CArray of shape `[ceil(elements / 8)]`,
  #     or `nil` when no mask is set.
  def validity_bits
    return nil unless has_mask?
    is_not_masked.reshape(-1).pack_bits
  end

end

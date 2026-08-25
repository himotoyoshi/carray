require "test/unit"
require "carray"

class TestPackBits < Test::Unit::TestCase

  # ---- pack_bits ---------------------------------------------------

  def test_pack_bits_boolean_multiple_of_8
    # 0xDB LSB-first = 1,1,0,1,1,0,1,1
    bools = CA_BOOLEAN([1,1,0,1,1,0,1,1])
    packed = bools.pack_bits
    assert_equal CA_UINT8, packed.data_type
    assert_equal [1],      packed.shape
    assert_equal 0xDB,     packed[0]
  end

  def test_pack_bits_boolean_with_tail
    # n = 10, bits: 1,0,1,0,1,1,0,0 | 1,0
    # byte0 LSB-first: 0x35 = 00110101
    # byte1 LSB-first: 0x01 = 00000001 (tail zero-filled)
    bools = CA_BOOLEAN([1,0,1,0,1,1,0,0,1,0])
    packed = bools.pack_bits
    assert_equal [2], packed.shape
    assert_equal 0x35, packed[0]
    assert_equal 0x01, packed[1]
  end

  def test_pack_bits_uint8_zero_one_source
    src = CA_UINT8([1,0,0,1,0,0,0,1])
    # LSB-first: bit0=1, bit1=0, bit2=0, bit3=1, ... → 0x89
    assert_equal 0x89, src.pack_bits[0]
  end

  def test_pack_bits_int8_source
    src = CA_INT8([1,0,1,1,0,0,0,0])
    # LSB-first: 0x0D = 00001101
    assert_equal 0x0D, src.pack_bits[0]
  end

  def test_pack_bits_empty
    empty = CArray.boolean(0)
    packed = empty.pack_bits
    assert_equal [0], packed.shape
    assert_equal CA_UINT8, packed.data_type
  end

  def test_pack_bits_roundtrip_via_bitarray
    # For n a multiple of 8, pack_bits and .bitarray unpack are exact inverses.
    packed = CA_UINT8([0xAB, 0xCD, 0x37])
    bools  = packed.bitarray.reshape(-1)
    re     = bools.pack_bits
    assert_equal packed.to_a, re.to_a
  end

  def test_pack_bits_rejects_non_1d
    ca = CArray.boolean(2, 4) { 0 }
    assert_raise(ArgumentError) { ca.pack_bits }
  end

  def test_pack_bits_rejects_wrong_dtype
    ca = CA_INT32([1,0,1,0,1,1,0,0])
    assert_raise(ArgumentError) { ca.pack_bits }
  end

  # ---- validity_bits ----------------------------------------------

  def test_validity_bits_no_mask_returns_nil
    ca = CArray.int32(10) { |i| i }
    assert_nil ca.validity_bits
  end

  def test_validity_bits_with_mask
    ca = CArray.int32(10) { |i| i }
    ca[2] = UNDEF
    ca[5] = UNDEF
    v = ca.validity_bits
    assert_equal CA_UINT8, v.data_type
    assert_equal [2],      v.shape
    # is_not_masked = 1,1,0,1,1,0,1,1,1,1 → byte0 0xDB, byte1 0x03
    assert_equal 0xDB, v[0]
    assert_equal 0x03, v[1]
  end

  def test_validity_bits_flattens_nd
    ca = CArray.int32(2, 4) { |i, j| i * 4 + j }
    ca[0, 1] = UNDEF   # flat index 1
    ca[1, 3] = UNDEF   # flat index 7
    v = ca.validity_bits
    # is_not_masked flat: 1,0,1,1,1,1,1,0 → 0x7D
    assert_equal [1], v.shape
    assert_equal 0x7D, v[0]
  end

  def test_validity_bits_all_masked
    ca = CArray.int32(8) { |i| i }
    ca[] = UNDEF
    v = ca.validity_bits
    assert_equal 0x00, v[0]
  end

end

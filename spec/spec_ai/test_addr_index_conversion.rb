# ----------------------------------------------------------------------------
#
#  spec_ai/test_addr_index_conversion.rb
#
#  Tests for CArray#addr2index / #index2addr and their class-form
#  counterparts CArray.addr2index(addr, shape:) / .index2addr(*i, shape:).
#
#  Scalar behaviour is preserved (Integer -> Array<Integer>).  CArray
#  input activates the vectorized path: shape-preserving per-axis output
#  with mask propagation and OOB raise.
#
# ----------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestAddrIndexConversion < Test::Unit::TestCase

  # ------------------------------------------------------------------
  # scalar path — unchanged legacy contract
  # ------------------------------------------------------------------

  def test_addr2index_scalar_returns_array_of_integers
    a = CArray.int32(3, 4, 5)
    assert_equal [1, 1, 1], a.addr2index(1*4*5 + 1*5 + 1)
    assert_equal [0, 0, 0], a.addr2index(0)
    assert_equal [2, 3, 4], a.addr2index(a.elements - 1)
  end

  def test_index2addr_scalar_returns_integer
    a = CArray.int32(3, 4, 5)
    assert_equal 26, a.index2addr(1, 1, 1)
    assert_kind_of Integer, a.index2addr(0, 0, 0)
  end

  def test_addr2index_scalar_oob_raises
    a = CArray.int32(3, 4)
    assert_raise(ArgumentError) { a.addr2index(12) }
    assert_raise(ArgumentError) { a.addr2index(-1) }
  end

  def test_addr2index_scalar_tuple_unpack
    a = CArray.int32(20, 60)
    i, j = a.addr2index(1 * 60 + 5)
    assert_equal [1, 5], [i, j]
  end

  # ------------------------------------------------------------------
  # vector path — CArray input
  # ------------------------------------------------------------------

  def test_addr2index_1d_carray_returns_per_axis_carrays
    a = CArray.int32(20, 60)
    addrs = CA_INT32([1*60+1, 2*60+2, 3*60+0, 3*60+1, 3*60+2])
    i, j = a.addr2index(addrs)
    assert_kind_of CArray, i
    assert_kind_of CArray, j
    assert_equal [5], i.shape
    assert_equal [5], j.shape
    assert_equal [1, 2, 3, 3, 3], i.to_a
    assert_equal [1, 2, 0, 1, 2], j.to_a
  end

  def test_addr2index_preserves_2d_shape
    a = CArray.int32(20, 60)
    addrs2d = CA_INT32([[0, 1], [60, 61]])
    i, j = a.addr2index(addrs2d)
    assert_equal [2, 2], i.shape
    assert_equal [[0, 0], [1, 1]], i.to_a
    assert_equal [[0, 1], [0, 1]], j.to_a
  end

  def test_addr2index_carray_oob_raises
    a = CArray.int32(20, 60)
    assert_raise(ArgumentError) { a.addr2index(CA_INT32([9999])) }
  end

  def test_addr2index_mask_propagates
    a = CArray.int32(20, 60)
    addrs = CA_INT32([61, 122, 180])
    addrs[1] = UNDEF
    i, j = a.addr2index(addrs)
    assert_equal [false, true, false], i.mask.to_a
    assert_equal [false, true, false], j.mask.to_a
    assert_equal 1, i[0]
    assert_equal 3, i[2]
  end

  def test_index2addr_carray_returns_carray
    a = CArray.int32(20, 60)
    i = CA_INT32([1, 2, 3])
    j = CA_INT32([1, 2, 0])
    addrs = a.index2addr(i, j)
    assert_kind_of CArray, addrs
    assert_equal [3], addrs.shape
    assert_equal [61, 122, 180], addrs.to_a
  end

  def test_index2addr_preserves_2d_shape
    a = CArray.int32(20, 60)
    i = CA_INT32([[0, 1], [2, 3]])
    j = CA_INT32([[0, 1], [2, 3]])
    addrs = a.index2addr(i, j)
    assert_equal [2, 2], addrs.shape
    assert_equal [[0, 61], [122, 183]], addrs.to_a
  end

  def test_index2addr_scalar_broadcast_with_carray
    a = CArray.int32(20, 60)
    j = CA_INT32([0, 1, 2])
    addrs = a.index2addr(3, j)
    assert_equal [180, 181, 182], addrs.to_a
  end

  def test_index2addr_shape_mismatch_raises
    a = CArray.int32(20, 60)
    assert_raise(ArgumentError) {
      a.index2addr(CA_INT32([1, 2]), CA_INT32([1, 2, 3]))
    }
  end

  def test_index2addr_mask_propagates
    a = CArray.int32(20, 60)
    i = CA_INT32([1, 2, 3])
    j = CA_INT32([1, 2, 0])
    i[1] = UNDEF
    addrs = a.index2addr(i, j)
    assert_equal [false, true, false], addrs.mask.to_a
  end

  # ------------------------------------------------------------------
  # round-trip
  # ------------------------------------------------------------------

  def test_round_trip_carray
    a = CArray.int32(4, 5, 6)
    addrs = CA_INT32([0, 7, 30, 60, 119])
    i, j, k = a.addr2index(addrs)
    assert_equal addrs.to_a, a.index2addr(i, j, k).to_a
  end

  def test_round_trip_2d_addrs
    a = CArray.int32(20, 60)
    addrs = CA_INT32([[0, 61], [122, 183]])
    i, j = a.addr2index(addrs)
    back = a.index2addr(i, j)
    assert_equal addrs.to_a, back.to_a
  end

  # ------------------------------------------------------------------
  # class form (shape: kwarg)
  # ------------------------------------------------------------------

  def test_class_addr2index_scalar
    assert_equal [1, 1], CArray.addr2index(61, shape: [20, 60])
  end

  def test_class_addr2index_carray
    addrs = CA_INT32([61, 122, 180])
    i, j = CArray.addr2index(addrs, shape: [20, 60])
    assert_equal [1, 2, 3], i.to_a
    assert_equal [1, 2, 0], j.to_a
  end

  def test_class_index2addr_scalar
    assert_equal 61, CArray.index2addr(1, 1, shape: [20, 60])
  end

  def test_class_index2addr_carray
    i = CA_INT32([1, 2, 3])
    j = CA_INT32([1, 2, 0])
    assert_equal [61, 122, 180],
                 CArray.index2addr(i, j, shape: [20, 60]).to_a
  end

  def test_class_missing_shape_raises
    assert_raise(ArgumentError) { CArray.addr2index(1) }
    assert_raise(ArgumentError) { CArray.index2addr(1, 1) }
  end

  def test_class_shape_ndim_mismatch_raises
    assert_raise(ArgumentError) {
      CArray.index2addr(1, 1, 1, shape: [20, 60])
    }
  end

  # ------------------------------------------------------------------
  # scatter cookbook shape (motivation)
  # ------------------------------------------------------------------

  def test_scatter_replace_via_index2addr
    h, w = 20, 60
    world = CArray.int32(h, w) { 0 }
    is = CA_INT32([1, 2, 3, 3, 3])
    js = CA_INT32([1, 2, 0, 1, 2])
    addrs = CArray.index2addr(is, js, shape: [h, w])
    world.scatter_replace!(addrs, 1)
    assert_equal 1, world[1, 1]
    assert_equal 1, world[2, 2]
    assert_equal 1, world[3, 0]
    assert_equal 1, world[3, 1]
    assert_equal 1, world[3, 2]
    assert_equal 5, world.sum
  end

  # ------------------------------------------------------------------
  # scatter_replace! on boolean self (assignment, no widening)
  # ------------------------------------------------------------------

  def test_scatter_replace_boolean_self_true_scalar
    h, w = 20, 60
    world = CArray.boolean(h, w) { false }
    is = CA_INT32([1, 2, 3, 3, 3])
    js = CA_INT32([1, 2, 0, 1, 2])
    addrs = CArray.index2addr(is, js, shape: [h, w])
    world.scatter_replace!(addrs, true)
    assert_equal true,  world[1, 1]
    assert_equal true,  world[2, 2]
    assert_equal true,  world[3, 0]
    assert_equal true,  world[3, 1]
    assert_equal true,  world[3, 2]
    assert_equal false, world[0, 0]
    assert_equal 5, world.count(true)
  end

  def test_scatter_replace_boolean_self_false_scalar
    world = CArray.boolean(4) { true }
    world.scatter_replace!(CA_INT32([1, 3]), false)
    assert_equal [true, false, true, false], world.to_a
  end

  def test_scatter_replace_boolean_self_vector_vals
    world = CArray.boolean(6) { false }
    addrs = CA_INT32([0, 2, 4])
    vals  = CA_BOOLEAN([true, false, true])
    world.scatter_replace!(addrs, vals)
    assert_equal [true, false, false, false, true, false], world.to_a
  end

  def test_scatter_replace_boolean_self_integer_scalar_accepted
    # Integer 0/1 is still accepted (goes through the numeric-scalar
    # branch; boolean is 0/1 storage).
    world = CArray.boolean(4) { false }
    world.scatter_replace!(CA_INT32([0, 2]), 1)
    assert_equal [true, false, true, false], world.to_a
  end

  def test_scatter_arithmetic_still_rejects_boolean
    world = CArray.boolean(4) { false }
    assert_raise(CArray::DataTypeError) {
      world.scatter_add!(CA_INT32([0]), 1)
    }
    assert_raise(CArray::DataTypeError) {
      world.scatter_min!(CA_INT32([0]), 0)
    }
  end

end

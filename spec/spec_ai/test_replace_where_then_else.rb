require 'test/unit'
require 'carray'

class TestReplaceWhereThenElse < Test::Unit::TestCase

  # --- replace_where ---

  def test_replace_where_scalar
    a = CArray.int32(6) {|i| i }
    cond = a.gt(2)
    r = a.replace_where(cond, -1)
    assert_equal([0, 1, 2, -1, -1, -1], r.to_a)
    # non-destructive
    assert_equal([0, 1, 2, 3, 4, 5], a.to_a)
  end

  def test_replace_where_carray_full_shape
    a = CArray.int32(6) {|i| i }
    b = CArray.int32(6) {|i| i * 10 }
    cond = a.gt(2)
    r = a.replace_where(cond, b)
    assert_equal([0, 1, 2, 30, 40, 50], r.to_a)
  end

  def test_replace_where_no_true
    a = CArray.int32(4) {|i| i }
    cond = a.lt(0)
    r = a.replace_where(cond, 99)
    assert_equal([0, 1, 2, 3], r.to_a)
  end

  def test_replace_where_all_true
    a = CArray.int32(4) {|i| i }
    cond = a.ge(0)
    r = a.replace_where(cond, 99)
    assert_equal([99, 99, 99, 99], r.to_a)
  end

  def test_replace_where_undef
    a = CArray.int32(5) {|i| i }
    cond = a.gt(1)
    r = a.replace_where(cond, UNDEF)
    assert(r.has_mask?)
    # idx 0-1 unmasked, 2-4 masked
    assert_equal([false, false, true, true, true], r.mask.to_a)
    assert_equal([0, 1], [r[0], r[1]])
  end

  def test_replace_where_2d
    a = CArray.int32(3, 3) {|i, j| i * 10 + j }
    cond = a.ge(20)
    r = a.replace_where(cond, 0)
    assert_equal([[0, 1, 2], [10, 11, 12], [0, 0, 0]], r.to_a)
  end

  # --- then_else ---

  def test_then_else_both_scalars
    cond = CArray.boolean(4) {|i| i.odd? }
    r = cond.then_else(10, 20)
    assert_equal([20, 10, 20, 10], r.to_a)
  end

  def test_then_else_both_carrays
    a = CArray.int32(5) {|i| i }
    cond = a.gt(2)
    r = cond.then_else(a, -a)
    assert_equal([0, -1, -2, 3, 4], r.to_a)
  end

  def test_then_else_scalar_x_carray_y
    a = CArray.int32(5) {|i| i }
    cond = a.gt(2)
    r = cond.then_else(100, a)
    assert_equal([0, 1, 2, 100, 100], r.to_a)
  end

  def test_then_else_carray_x_scalar_y
    a = CArray.int32(5) {|i| i }
    cond = a.gt(2)
    r = cond.then_else(a, 99)
    assert_equal([99, 99, 99, 3, 4], r.to_a)
  end

  def test_then_else_undef_in_cond_propagates
    a = CArray.int32(5) {|i| i }
    cond = a.gt(1).copy
    cond[2] = UNDEF
    r = cond.then_else(1, 0)
    expected = [0, 0, nil, 1, 1]  # nil = UNDEF position
    actual = r.to_a.each_with_index.map {|v, i| r.mask[i] ? nil : v }
    assert_equal(expected, actual)
    assert(r.has_mask?)
  end

  def test_then_else_2d
    a = CArray.int32(2, 3) {|i, j| i * 10 + j }
    cond = a.ge(10)
    r = cond.then_else(-1, a)
    assert_equal([[0, 1, 2], [-1, -1, -1]], r.to_a)
  end

  def test_then_else_float_promotion_both_scalars
    cond = CArray.boolean(3) {|i| i.even? }
    r = cond.then_else(1.5, 0)
    assert_equal(CA_FLOAT64, r.data_type)
    assert_equal([1.5, 0.0, 1.5], r.to_a)
  end

  def test_then_else_promotion_int_carray_x_float_scalar_y
    # Pre-result_type bug: int32 x + float scalar y landed on int32 and
    # silently truncated y to floor.  result_type promotes to float64.
    a = CArray.int32(4) {|i| i }
    cond = a.gt(1)
    r = cond.then_else(a, 1.5)
    assert_equal(CA_FLOAT64, r.data_type)
    assert_equal([1.5, 1.5, 2.0, 3.0], r.to_a)
  end

  def test_then_else_promotion_int_scalar_x_float_carray_y
    b = CArray.float64(4) {|i| i + 0.5 }
    cond = CArray.boolean(4) {|i| i < 2 }
    r = cond.then_else(7, b)
    assert_equal(CA_FLOAT64, r.data_type)
    assert_equal([7.0, 7.0, 2.5, 3.5], r.to_a)
  end

  # --- equivalence ---

  def test_replace_where_then_else_equivalence
    a = CArray.int32(8) {|i| i }
    b = CArray.int32(8) {|i| -i }
    cond = a.gt(3)
    # a.replace_where(cond, b) == cond.then_else(b, a)
    r1 = a.replace_where(cond, b)
    r2 = cond.then_else(b, a)
    assert_equal(r1.to_a, r2.to_a)
  end

  # --- data_type guards ---

  def test_replace_where_rejects_non_boolean_cond
    a = CArray.int32(5) {|i| i }
    int_cond = CArray.int32(5) {|i| i }  # not boolean
    assert_raise(ArgumentError) do
      a.replace_where(int_cond, -1)
    end
  end

  def test_replace_where_rejects_non_carray_cond
    a = CArray.int32(5) {|i| i }
    assert_raise(ArgumentError) do
      a.replace_where([true, false, true, false, true], -1)
    end
  end

  def test_then_else_cscalar_keeps_type
    cond = CA_INT([1, 2, 3, 4]).gt(2)
    i32  = CA_INT([1, 2, 3, 4])
    # CScalar branch is treated as a scalar (broadcast), keeping its type
    # (CA_INT32(0) -> int32) unlike a bare Ruby Integer (-> int64).
    r = cond.then_else(CA_INT32(0), i32)
    assert_equal :int32, r.data_type
    assert_equal [1, 2, 0, 0], r.to_a
    assert_equal :int64, cond.then_else(0, i32).data_type
  end

  def test_then_else_rejects_non_boolean_receiver
    int_self = CArray.int32(5) {|i| i }
    assert_raise(ArgumentError) do
      int_self.then_else(1, 0)
    end
  end

  def test_indexer_setter_pair
    # a.replace_where(cond, b) is the functional sibling of `a[cond] = b`.
    a = CArray.int32(6) {|i| i }
    cond = a.gt(2)
    r = a.replace_where(cond, -1)

    a2 = a.copy
    a2[cond] = -1
    assert_equal(a2.to_a, r.to_a)
  end

end

# CAStack / CAMeld: the views with K parents, against the same operation on
# an entity (.copy).
#
#  - xfer_stride reads a request as a box over the view's own axes only when
#    it is one; a size-1 axis (two axes with the same native stride) or a
#    flat window reshaped back to ndim falls to the per-cell walk
#  - a Face parent is lifted, a mix of Face and non-Face is refused
#  - the mask: a copy of a stack's mask writes to the parents' masks; a
#    value-array parent takes value writes
#  - the meld reduction fast path answers as the core path does

require 'test/unit'
require 'carray'

class TestStackMeldMultiParent < Test::Unit::TestCase

  # ---------- xfer_stride: requests that are not boxes ----------

  def test_stack_transpose_over_size1_axis
    s = CArray.stack([CA_INT32([[1, 2, 3]]), CA_INT32([[4, 5, 6]])])
    v = s.transpose(1, 0, 2)
    assert_equal [[[1, 2, 3], [4, 5, 6]]], v.to_a
    assert_equal s.copy.transpose(1, 0, 2).to_a, v.copy.to_a
  end

  def test_meld_transpose_over_size1_axis
    m = CArray.meld(CA_INT32([[1], [2], [3]]), CA_INT32([[4], [5]]))
    assert_equal [[1, 2, 3, 4, 5]], m.transpose.to_a
    assert_equal 15, m.transpose.sum
  end

  def test_meld_transpose_write_lands_in_parents
    a = CA_FLOAT64([[1], [2], [3]])
    b = CA_FLOAT64([[4], [5]])
    m = CArray.meld(a, b)
    m.transpose[] = CA_FLOAT64([[10, 20, 30, 40, 50]])
    assert_equal [[10.0], [20.0], [30.0]], a.to_a
    assert_equal [[40.0], [50.0]], b.to_a
  end

  def test_stack_reshaped_window_wraps_across_axis
    ps = [CA_INT32([1, 2, 3]), CA_INT32([4, 5, 6]), CA_INT32([7, 8, 9])]
    s = CArray.stack(ps)
    w = s.reshape(9)[1..6].reshape(2, 3)
    assert_equal [[2, 3, 4], [5, 6, 7]], w.to_a
    assert_equal 27, w.sum
    w[] = CA_INT32([[-1, -2, -3], [-4, -5, -6]])
    assert_equal [[1, -1, -2], [-3, -4, -5], [-6, 8, 9]], ps.map(&:to_a)
  end

  def test_stack_k_axis_reshaped_window
    ps = (0...3).map { |j| CArray.int32(4).seq(10 * j) }
    s = CArray.stack(ps, axis: 1)
    w = s.reshape(12)[2..7].reshape(2, 3)
    assert_equal s.copy.reshape(12)[2..7].reshape(2, 3).to_a, w.to_a
  end

  def test_meld_internal_axis_reshaped_window
    m = CArray.meld(CA_INT32([[1, 2], [3, 4], [5, 6], [7, 8]]),
                    CA_INT32([[9], [10], [11], [12]]), axis: 1)
    w = m.reshape(12)[1..6].reshape(2, 3)
    assert_equal [[2, 9, 3], [4, 10, 5]], w.to_a
  end

  # ---------- Face parents ----------

  def test_stack_of_one_face_is_lifted
    t = CArray.time(["2024-01-01", "2024-01-02"], unit: :D)
    s = CArray.stack([t])
    assert_kind_of CATime, s
    assert_equal t[1], s[0, 1]
  end

  def test_stack_of_one_const_string_is_lifted
    cs = CArray.const_string(["ab", "cde"])
    assert_equal [["ab", "cde"]], CArray.stack([cs]).to_a
  end

  def test_mixing_face_and_non_face_is_refused
    t  = CArray.time(["2024-01-01", "2024-01-02"], unit: :D)
    td = CA_INT64([1, 2]).timedelta(unit: :s)
    raw = CArray.int64(2).seq
    assert_raise(ArgumentError) { CArray.meld(t, raw) }
    assert_raise(ArgumentError) { CArray.meld(t, td) }
    assert_raise(ArgumentError) { CAMeld.new([raw, t]) }
    assert_raise(ArgumentError) { CAStack.new([t, raw]) }
  end

  # ---------- mask ----------

  def test_copy_of_the_mask_writes_to_the_parents
    a = CArray.int32(3).seq!; a[1] = UNDEF
    b = CArray.int32(3).seq!(10)
    s = CArray.stack([a, b])
    md = s.mask.dup
    md[1, 0] = 1
    assert_equal [UNDEF, 11, 12], b.to_a
    assert_equal CArray.stack([a, b]).to_a, s.to_a
    s.mask[1, 2] = 1
    assert_equal [UNDEF, 11, UNDEF], b.to_a
  end

  def test_copy_of_meld_mask_writes_to_the_parents
    a = CArray.int32(3).seq!; a[1] = UNDEF
    b = CArray.int32(2).seq!(10)
    m = CArray.meld(a, b)
    m.mask.dup[3] = 1
    assert_equal [UNDEF, 11], b.to_a
  end

  def test_value_array_parent_takes_writes
    a = CArray.int32(2, 3).seq!; a[1] = UNDEF
    b = CArray.int32(2, 3).seq!(10); b[5] = UNDEF
    s = CArray.stack([a.value, b])
    s[1, 0, 0] = 8
    s[0, 0, 0] = 7
    assert_equal 8, b[0, 0]
    assert_equal 7, a.value[0, 0]
    s[1, 0, 1] = UNDEF
    assert_equal UNDEF, b[0, 1]
    assert_equal [[false, true, false], [false, false, false]],
                 a.is_masked.to_a
    s[] = 1
    assert_equal [[1] * 3] * 2, b.to_a
    m = CArray.meld(a.value, CArray.int32(2, 3).tap { |x| x[0] = UNDEF })
    m[3, 0] = 8
    assert_equal 8, m[3, 0]
  end

  def test_undef_into_value_array_parent_is_refused
    a = CArray.int32(2, 3).seq!; a[1] = UNDEF
    b = CArray.int32(2, 3).seq!(10); b[5] = UNDEF
    s = CArray.stack([a.value, b])
    assert_raise(TypeError) { s[0, 0, 2] = UNDEF }
    assert_equal false, s.is_masked[0, 0, 2]
    assert_equal [[false, true, false], [false, false, false]],
                 a.is_masked.to_a
  end

  # ---------- meld reduction fast path ----------

  def test_one_dimensional_meld_along_its_axis
    m = CArray.meld(CA_FLOAT64([3, 1, 4]), CA_FLOAT64([1, 5]))
    c = m.copy
    [:min, :max, :sum, :mean, :variance, :variancep,
     :stddev, :stddevp].each do |op|
      assert_in_delta c.send(op, axis: 0), m.send(op, axis: 0), 1e-12, op.to_s
    end
  end

  def test_object_meld_mean_stays_exact
    m = CArray.meld(CA_OBJECT([Rational(1, 3), Rational(1, 2)]),
                    CA_OBJECT([Rational(2, 7)]))
    assert_equal Rational(47, 126), m.mean
    assert_equal 2, CArray.meld(CA_OBJECT([1, 2]), CA_OBJECT([4])).mean
  end

  def test_complex_meld_variance
    z1 = CArray.cmplx128(3) { |i| Complex(i, 2 * i + 1) }
    z2 = CArray.cmplx128(4) { |i| Complex(-i, i * i) }
    m = CArray.meld(z1, z2)
    c = m.copy
    [:variance, :variancep, :stddev, :stddevp].each do |op|
      assert_in_delta c.send(op), m.send(op), 1e-12, op.to_s
    end
  end

  def test_face_meld_reductions
    d = CArray.meld(CA_INT64([3, 10, 4]).timedelta(unit: :s),
                    CA_INT64([7, 1]).timedelta(unit: :s))
    assert_equal d.copy.mean, d.mean
    assert_equal d.copy.stddev, d.stddev
    t = CArray.meld(CA_INT64([[3, 10], [4, 5]]).time(unit: :D),
                    CA_INT64([[7, 1]]).time(unit: :D))
    assert_equal t.copy.mean, t.mean
    assert_equal t.copy.mean(axis: 1).to_a, t.mean(axis: 1).to_a
    assert_equal t.copy.stddev(axis: 1).to_a, t.stddev(axis: 1).to_a
  end

end

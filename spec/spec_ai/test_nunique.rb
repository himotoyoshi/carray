# Test for CArray#nunique (value-hash discovery family, scalar reduction).
#
# Contract (PROPOSAL_VALUE_COUNTS_NUNIQUE):
#   - axis: nil (default) returns an Integer count of distinct values over the
#     whole array. axis: k returns a reduced CA_INT64 CArray (axis k dropped,
#     or kept length-1 with keep_axis: true).
#   - Identity 0: empty / all-masked fiber / zero-length axis counts 0 (not
#     UNDEF). Masked cells do not participate.
#   - Numeric distinctness is `==` with all NaN collapsed and -0.0 == +0.0.
#     CA_OBJECT / CA_FIXLEN follow Ruby eql?/hash.

require "test/unit"
require "carray"

class TestNunique < Test::Unit::TestCase

  def test_flat_integer
    assert_equal 3, CA_INT32([3, 1, 3, 2, 1, 3]).nunique
    assert_kind_of Integer, CA_INT32([1, 1]).nunique
  end

  def test_flat_no_duplicates
    assert_equal 3, CA_INT32([5, 6, 7]).nunique
  end

  def test_flat_multidim
    assert_equal 3, CA_INT32([[1, 2], [2, 3]]).nunique
  end

  def test_per_axis_rows
    m = CA_INT32([[1, 1, 2], [3, 3, 3], [4, 5, 6]])
    assert_equal [2, 1, 3], m.nunique(axis: 1).to_a
    assert_equal CA_INT64, m.nunique(axis: 1).data_type
  end

  def test_per_axis_cols
    m = CA_INT32([[1, 1, 2], [3, 3, 3], [4, 5, 6]])
    assert_equal [3, 3, 3], m.nunique(axis: 0).to_a
  end

  def test_keep_axis
    m = CA_INT32([[1, 1, 2], [3, 3, 3], [4, 5, 6]])
    assert_equal [[2], [1], [3]], m.nunique(axis: 1, keep_axis: true).to_a
  end

  def test_reduced_shape_matches_sum
    m = CA_INT32([[1, 2, 3], [4, 5, 6]])
    assert_equal m.sum(axis: 1).shape, m.nunique(axis: 1).shape
    assert_equal m.sum(axis: 0).shape, m.nunique(axis: 0).shape
  end

  def test_float_nan_collapse_flat
    nan = Float::NAN
    assert_equal 3, CA_FLOAT64([1.0, nan, 2.0, nan, 1.0, nan]).nunique
  end

  def test_float_nan_collapse_per_axis
    nan = Float::NAN
    f = CA_FLOAT64([[1.0, nan, nan], [nan, 1.0, 2.0]])
    assert_equal [2, 3], f.nunique(axis: 1).to_a
  end

  def test_signed_zero_collapse
    assert_equal 1, CA_FLOAT64([-0.0, 0.0, 0.0]).nunique
  end

  def test_masked_cells_excluded
    a = CA_INT32([1, 1, 2, 2, 3])
    a[0] = UNDEF
    assert_equal 3, a.nunique
  end

  def test_all_masked_fiber_is_zero
    mm = CA_INT32([[1, 2, 3], [9, 9, 9]])
    mm.mask = CA_BOOLEAN([[1, 1, 1], [0, 0, 0]])
    assert_equal [0, 1], mm.nunique(axis: 1).to_a
  end

  def test_all_masked_flat_is_zero
    a = CA_INT32([5, 5, 5]); a.mask = 1
    assert_equal 0, a.nunique
  end

  def test_object_flat
    o = CA_OBJECT(["a", "b", "a", "c"])
    assert_equal 3, o.nunique
  end

  def test_object_nan_collapse
    # distinct NaN objects count as one distinct value, matching the numeric lane
    nan1 = Float::NAN
    nan2 = Float::INFINITY - Float::INFINITY
    assert_equal 3, CA_OBJECT([1.0, nan1, 2.0, nan2, 1.0, nan1]).nunique
  end

  def test_object_per_axis
    o = CA_OBJECT([["a", "b", "a"], ["c", "b", "d"]])
    assert_equal [2, 3], o.nunique(axis: 1).to_a
    assert_equal CA_INT64, o.nunique(axis: 1).data_type
  end

  def test_object_keep_axis
    o = CA_OBJECT([["a", "b", "a"], ["c", "b", "d"]])
    assert_equal [[2], [3]], o.nunique(axis: 1, keep_axis: true).to_a
  end

  def test_fixlen_flat
    fx = CArray.fixlen(4, bytes: 2) { |i| ["ab", "cd", "ab", "ef"][i] }
    assert_equal 3, fx.nunique
  end

  def test_agrees_with_unique_size
    a = CA_INT32([4, 4, 1, 2, 4, 1, 9])
    assert_equal a.unique.size, a.nunique
  end

end

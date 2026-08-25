# Test for CArray#value_counts (value-hash discovery family, frequency table).
#
# Contract (PROPOSAL_VALUE_COUNTS_NUNIQUE):
#   - Returns [values, counts]: values is 1-D of self's dtype in first-
#     appearance order, counts is 1-D CA_INT64 with per-value occurrences.
#   - sort: false (default) appearance order; :count descending frequency
#     (ties keep appearance order); :value ascending (NaN last).
#   - Masked cells never appear; all-masked yields two empty CArrays.
#   - Numeric distinctness is `==` with all NaN collapsed to one value (counts
#     add) and -0.0 == +0.0 (first-seen value kept). CA_OBJECT / CA_FIXLEN
#     follow Ruby eql?/hash and keep self's dtype.
#   - Always flat (per-fiber counts would be ragged), like #unique.

require "test/unit"
require "carray"

class TestValueCounts < Test::Unit::TestCase

  def test_integer_appearance_order
    v, c = CA_INT32([3, 1, 3, 2, 1, 3]).value_counts
    assert_equal [3, 1, 2], v.to_a
    assert_equal [3, 2, 1], c.to_a
    assert_equal CA_INT32, v.data_type
    assert_equal CA_INT64, c.data_type
    assert_equal 1, v.ndim
  end

  def test_no_duplicates_all_ones
    v, c = CA_INT32([5, 6, 7]).value_counts
    assert_equal [5, 6, 7], v.to_a
    assert_equal [1, 1, 1], c.to_a
  end

  def test_multidim_row_major_flatten
    v, c = CA_INT32([[1, 2], [2, 3]]).value_counts
    assert_equal [1, 2, 3], v.to_a
    assert_equal [1, 2, 1], c.to_a
  end

  def test_uint_and_int64
    v, c = CA_UINT8([7, 3, 7, 9, 3, 7]).value_counts
    assert_equal [7, 3, 9], v.to_a
    assert_equal [3, 2, 1], c.to_a
    assert_equal CA_UINT8, v.data_type
  end

  def test_sort_count_descending
    v, c = CA_INT32([1, 2, 2, 3, 3, 3]).value_counts(sort: :count)
    assert_equal [3, 2, 1], v.to_a
    assert_equal [3, 2, 1], c.to_a
  end

  def test_sort_count_ties_keep_appearance_order
    # 2 and 1 both occur twice; 2 appears first in the array, so it comes first.
    v, c = CA_INT32([2, 2, 1, 1, 3]).value_counts(sort: :count)
    assert_equal [2, 1, 3], v.to_a
    assert_equal [2, 2, 1], c.to_a
  end

  def test_sort_value_ascending
    v, c = CA_INT32([3, 1, 3, 2, 1]).value_counts(sort: :value)
    assert_equal [1, 2, 3], v.to_a
    assert_equal [2, 1, 2], c.to_a
  end

  def test_float_appearance_order
    v, c = CA_FLOAT64([1.5, 2.5, 1.5, 3.5, 2.5]).value_counts
    assert_equal [1.5, 2.5, 3.5], v.to_a
    assert_equal [2, 2, 1], c.to_a
  end

  def test_nan_collapses_and_counts_add
    nan = Float::NAN
    v, c = CA_FLOAT64([1.0, nan, 2.0, nan, 1.0, nan]).value_counts
    assert_equal 3, v.size
    assert_equal 1.0, v[0]
    assert v[1].nan?
    assert_equal 2.0, v[2]
    assert_equal [2, 3, 1], c.to_a
  end

  def test_nan_sorts_last_by_value
    nan = Float::NAN
    v, c = CA_FLOAT64([nan, 3.0, nan, 1.0]).value_counts(sort: :value)
    assert_equal [1.0, 3.0], v.to_a[0, 2]
    assert v.to_a[2].nan?
    assert_equal [1, 1, 2], c.to_a
  end

  def test_signed_zero_collapses_keeps_first_sign
    v, c = CA_FLOAT64([-0.0, 0.0, 0.0, 5.0]).value_counts
    assert_equal [-0.0, 5.0], v.to_a
    assert_equal [3, 1], c.to_a
    assert (1.0 / v[0]) < 0   # first-seen -0.0 sign preserved
  end

  def test_masked_cells_excluded
    a = CA_INT32([1, 1, 2, 2, 3])
    a[0] = UNDEF
    v, c = a.value_counts
    assert_equal [1, 2, 3], v.to_a
    assert_equal [1, 2, 1], c.to_a
  end

  def test_all_masked_yields_empty
    a = CA_INT32([5, 5, 5]); a.mask = 1
    v, c = a.value_counts
    assert_equal [], v.to_a
    assert_equal [], c.to_a
    assert_equal 0, v.size
  end

  def test_object_dtype_ruby_semantics
    o = CA_OBJECT(["a", "b", "a", "c", "b", "a"])
    v, c = o.value_counts
    assert_equal ["a", "b", "c"], v.to_a
    assert_equal [3, 2, 1], c.to_a
    assert_equal CA_OBJECT, v.data_type
  end

  def test_object_sort_count
    o = CA_OBJECT(["x", "y", "y", "z", "z", "z"])
    v, c = o.value_counts(sort: :count)
    assert_equal ["z", "y", "x"], v.to_a
    assert_equal [3, 2, 1], c.to_a
  end

  def test_object_nan_collapses_and_counts_add
    # distinct NaN objects collapse to one level, counts add, matching numeric
    nan1 = Float::NAN
    nan2 = Float::INFINITY - Float::INFINITY
    v, c = CA_OBJECT([1.0, nan1, 2.0, nan2, 1.0, nan1]).value_counts
    assert_equal 3, v.size
    assert_equal 1, v.to_a.count { |x| x.is_a?(Float) && x.nan? }
    nan_i = v.to_a.index { |x| x.is_a?(Float) && x.nan? }
    assert_equal 3, c[nan_i]
  end

  def test_fixlen_keeps_dtype
    fx = CArray.fixlen(6, bytes: 3) { |i| ["ab", "cd", "ab", "ef", "cd", "ab"][i] }
    v, c = fx.value_counts
    assert_equal CA_FIXLEN, v.data_type
    assert_equal [3, 2, 1], c.to_a
  end

  def test_invalid_sort_raises
    assert_raise(ArgumentError) { CA_INT32([1, 2]).value_counts(sort: :nope) }
  end

  def test_counts_sum_equals_present_cells
    a = CA_INT32([4, 4, 1, 2, 4, 1, 9])
    _, c = a.value_counts
    assert_equal 7, c.sum
  end

end

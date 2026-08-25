# spec_ai/test_e6a_count_true_false.rb
#
# PROPOSAL_E6_COUNT_FAMILY E.6a regression pin (2026-06-03).
#
# count_true / count_false rewired from carray_stat.c hand-written
# implementations to mkkernel-generated kernels (count_true_ki /
# count_false_ki).  This adds **per-axis** capability (previously
# flatten-only) while preserving legacy semantics:
#   - boolean-only source (DataTypeError on non-bool)
#   - Ruby Integer return for full reduction
#   - mask-aware via :min_count policy
#   - (min_count:, fill_value:) options for "too many missing" handling
#   - output data_type = CA_INT32 (legacy parity)

require "test/unit"
require "carray"

class TestE6aCountTrueFalse < Test::Unit::TestCase
  # --- correctness: flatten (legacy parity) ---

  def test_flatten_count_true_returns_integer
    a = CArray.boolean(8)
    a[] = [1, 0, 1, 0, 1, 0, 1, 0]
    assert_equal Integer, a.count(true).class
    assert_equal 4, a.count(true)
  end

  def test_flatten_count_false_returns_integer
    a = CArray.boolean(8)
    a[] = [1, 0, 1, 0, 1, 0, 1, 0]
    assert_equal Integer, a.count(false).class
    assert_equal 4, a.count(false)
  end

  def test_empty_array_returns_zero
    # ERI (2026-07-04): a count has identity 0, so empty / all-masked input
    # returns 0, not UNDEF -- consistent with sum -> 0 and count(v). This
    # realigns count_true / count_false with count_equal's identity_on_empty
    # (they were missed when ERI landed).
    e = CArray.boolean(0)
    assert_equal 0, e.count(true)
    assert_equal 0, e.count(false)
  end

  def test_non_boolean_raises_type_error
    # CF.2 Q3 strict: numeric array rejects true/false with TypeError
    # at the dispatch layer (= count(v) on int32/f64 rejects bool literal
    # before even reaching the kernel).  Previously raised CArray::
    # DataTypeError from the kernel itself; the new dispatch wraps with
    # a clearer Ruby-level TypeError.
    assert_raise(TypeError) do
      CArray.int32(5).seq.count(true)
    end
    assert_raise(TypeError) do
      CArray.float64(5).seq.count(false)
    end
  end

  # --- per-axis (NEW capability via mkkernel) ---

  def test_per_axis_returns_carray
    b = CArray.boolean(3, 4)
    b[] = [[1, 0, 1, 0], [0, 1, 0, 1], [1, 0, 1, 0]]
    r0 = b.count(true, axis: 0)
    r1 = b.count(true, axis: 1)
    assert_kind_of CArray, r0
    assert_kind_of CArray, r1
    assert_equal [2, 1, 2, 1], r0.to_a
    assert_equal [2, 2, 2], r1.to_a
  end

  def test_per_axis_count_false
    b = CArray.boolean(3, 4)
    b[] = [[1, 0, 1, 0], [0, 1, 0, 1], [1, 0, 1, 0]]
    r0 = b.count(false, axis: 0)
    assert_equal [1, 2, 1, 2], r0.to_a
  end

  def test_per_axis_output_data_type_int64
    # count(true/false) outputs i64, consistent with count(v) numeric: a
    # count is bounded by `elements` which can exceed INT32_MAX (was i32
    # for legacy parity with the retired carray_stat.c count_true/false).
    b = CArray.boolean(3, 4); b[] = 0
    assert_equal CA_INT64, b.count(true, axis: 0).data_type
    assert_equal CA_INT64, b.count(false, axis: 1).data_type
  end

  def test_full_reduction_after_per_axis
    b = CArray.boolean(3, 4)
    b[] = [[1, 0, 1, 0], [0, 1, 0, 1], [1, 0, 1, 0]]
    assert_equal 6, b.count(true)
    assert_equal 6, b.count(false)
  end

  # --- mask semantics (legacy parity) ---

  def test_mask_skips_cells
    c = CArray.boolean(5)
    c[] = [0, 1, 0, 1, 0]
    c.mask = [0, 0, 1, 0, 0]   # mask idx 2 (which is 0 anyway)
    # 2 unmasked trues (idx 1, 3), 2 unmasked falses (idx 0, 4)
    assert_equal 2, c.count(true)
    assert_equal 2, c.count(false)
  end

  def test_min_count_option_returns_undef_when_too_few_valid
    m = CArray.boolean(5)
    m[] = [0, 1, 0, 1, 0]
    m.mask = [0, 1, 1, 1, 0]   # 3 masked, only 2 valid
    # min_count: 3 requires 3 valid cells; only 2 valid -> UNDEF
    assert_equal UNDEF, m.count(true, min_count: 3)
  end

  def test_min_count_with_fill_value
    m = CArray.boolean(5)
    m[] = [0, 1, 0, 1, 0]
    m.mask = [0, 1, 1, 1, 0]
    assert_equal(-1, m.count(true, min_count: 3, fill_value: -1))
  end

  def test_min_count_satisfied_returns_count
    m = CArray.boolean(5)
    m[] = [0, 1, 0, 1, 0]
    m.mask = [0, 0, 1, 0, 0]   # 1 masked, 4 valid
    # min_count: 3 satisfied (4 valid >= 3)
    assert_equal 2, m.count(true, min_count: 3)
  end

  # --- per-axis + mask ---

  def test_per_axis_with_mask
    b = CArray.boolean(2, 4)
    b[] = [[1, 0, 1, 0], [0, 1, 0, 1]]
    b.mask = [[0, 0, 1, 0], [0, 0, 0, 0]]  # mask (0, 2)
    r0 = b.count(true, axis: 0)
    # axis 0 reduce, output shape [4]:
    # col 0: [1, 0] -> 1 true (no mask)
    # col 1: [0, 1] -> 1 true
    # col 2: [_, 0] -> 0 true (idx 0 masked)
    # col 3: [0, 1] -> 1 true
    assert_equal [1, 1, 0, 1], r0.to_a
  end
end

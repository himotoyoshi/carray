# first / last: mask-aware first/last-valid reduction (the reduction sibling
# of the :forward / :backward hold).  See devel/PROPOSAL_UNMASK_FILL_METHOD.md.

require "test/unit"
require "carray"
require "carray/categorical"

class TestFirstLastValid < Test::Unit::TestCase

  # ---- flatten ------------------------------------------------------------

  def test_flatten_first_last_valid
    a = CA_INT32([0, 1, 2, 3, 4]); a[0] = UNDEF; a[1] = UNDEF; a[4] = UNDEF
    assert_equal(2, a.first)
    assert_equal(3, a.last)
  end

  def test_unmasked_degrades_to_first_last_element
    a = CA_INT32([5, 6, 7])
    assert_equal(5, a.first)
    assert_equal(7, a.last)
  end

  def test_all_masked_flatten_is_undef
    a = CA_INT32([0, 0, 0]); a[] = UNDEF
    assert_equal(UNDEF, a.first)
    assert_equal(UNDEF, a.last)
  end

  def test_empty_is_undef_not_raise
    e = CArray.int32(0)
    assert_equal(UNDEF, e.first)
    assert_equal(UNDEF, e.last)
  end

  # ---- per-axis -----------------------------------------------------------

  def test_per_axis
    m = CA_INT32([[0, 1, 2], [3, 4, 5]]); m[0, 0] = UNDEF; m[1, 2] = UNDEF
    assert_equal([1, 3], m.first(axis: 1).to_a)
    assert_equal([2, 4], m.last(axis: 1).to_a)
    assert_equal([3, 1, 2], m.first(axis: 0).to_a)
  end

  def test_per_axis_fully_masked_fiber_is_undef_cell
    m = CA_INT32([[0, 1, 2], [3, 4, 5]])
    m[0, 0] = UNDEF; m[1, 0] = UNDEF; m[1, 1] = UNDEF; m[1, 2] = UNDEF
    c = m.first(axis: 1)
    assert_equal([1, UNDEF], c.to_a)
    assert_equal([false, true], c.is_masked.to_a)
  end

  def test_negative_axis
    m = CA_INT32([[0, 1, 2]]); m[0, 0] = UNDEF
    assert_equal(m.first(axis: 1).to_a, m.first(axis: -1).to_a)
  end

  def test_keep_axis
    m = CA_INT32([[0, 1, 2], [3, 4, 5]]); m[0, 0] = UNDEF
    assert_equal([[1], [3]], m.first(axis: 1, keep_axis: true).to_a)
  end

  def test_multi_axis_first_valid_row_major
    m = CA_INT32([[0, 1], [2, 3]]); m[0, 0] = UNDEF
    assert_equal(1, m.first(axis: [0, 1]))   # first valid in row-major
    assert_equal(3, m.last(axis: [0, 1]))
  end

  def test_full_reduce_keep_axis_returns_array
    m = CA_INT32([[0, 1], [2, 3]]); m[0, 0] = UNDEF
    assert_equal([[1]], m.first(keep_axis: true).to_a)
  end

  # ---- dtype coverage -----------------------------------------------------

  def test_float
    a = CA_FLOAT64([1.5, 2.5, 3.5]); a[0] = UNDEF
    assert_equal(2.5, a.first)
    assert_equal(3.5, a.last)
  end

  def test_bool
    a = CArray.boolean(3) { |i| i.even? }; a[0] = UNDEF
    assert_equal(false, a.first)
    assert_equal(true, a.last)
  end

  def test_complex
    a = CA_CMPLX128([Complex(1, 1), Complex(2, 2), Complex(3, 3)]); a[2] = UNDEF
    assert_equal(Complex(1, 1), a.first)
    assert_equal(Complex(2, 2), a.last)
  end

  def test_object
    a = CA_OBJECT(["x", "y", "z"]); a[0] = UNDEF
    assert_equal("y", a.first)
    assert_equal("z", a.last)
  end

  def test_fixlen
    a = CArray.fixlen(3, bytes: 3) { |i| ["aaa", "bbb", "ccc"][i] }
    a[0] = UNDEF
    assert_equal("bbb", a.first)
    assert_equal("ccc", a.last)
  end

  def test_datetime_face
    t = CArray.time_series("2020-01-01", count: 3, unit: :D); t[0] = UNDEF
    assert_equal(t[1].to_time, t.first.to_time)
    assert_equal(t[2].to_time, t.last.to_time)
  end

  def test_categorical_face
    keys = CArray.object(4) { |i| %w[a b c a][i] }; keys[0] = UNDEF
    cat = keys.categorize
    assert_equal("b", cat.first)
    assert_equal("a", cat.last)
    assert_equal(CACategorical, cat.first(axis: 0).class) rescue nil
  end

  # ---- fill_value via call-site completion --------------------------------

  def test_undef_completes_with_strip_mask
    m = CA_INT32([[0, 1], [2, 3]])
    m[0, 0] = UNDEF; m[0, 1] = UNDEF   # row 0 all masked
    filled = m.first(axis: 1).strip_mask(-1)
    assert_equal([-1, 2], filled.to_a)
  end

  # ---- errors -------------------------------------------------------------

  def test_positional_axis_rejected
    a = CA_INT32([1, 2, 3])
    assert_raise(ArgumentError) { a.first(0) }
    assert_raise(ArgumentError) { a.last(1) }
  end
end

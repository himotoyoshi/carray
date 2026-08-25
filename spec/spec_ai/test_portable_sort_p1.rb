# PROPOSAL_PORTABLE_TEXTBOOK_SORT P.1 — smoke + parity gates for the new
# portable textbook quicksort + mergesort kernels (f64 only at P.1).
#
# Surfaces under test:
#   CArray#_sort_copy_quick_v2   (dev-only, f64 1-D, no axis, no mask)
#   CArray#_sort_copy_merge_v2   (dev-only, f64 1-D, no axis, no mask)
#
# Skipped in release build (= smoke methods gated by CARRAY_DEV_BUILD).

require 'carray'
require 'test/unit'

unless CArray.instance_methods.include?(:_sort_copy_quick_v2)
  warn "test_portable_sort_p1: dev-only smoke methods not available " \
       "(release build?  rebuild with CARRAY_DEV=1)"
  return
end

class TestPortableSortP1 < Test::Unit::TestCase

  # ---------- correctness vs reference ----------------------------------

  def test_quick_sorts_random_n100
    a = CArray.float64(100).seq.shuffle!
    out = a._sort_copy_quick_v2
    assert_equal a.to_a.sort, out.to_a
  end

  def test_merge_sorts_random_n100
    a = CArray.float64(100).seq.shuffle!
    out = a._sort_copy_merge_v2
    assert_equal a.to_a.sort, out.to_a
  end

  def test_quick_sorts_large_random_n10k
    srand(20260612)
    a = CArray.float64(10_000) { |i| rand }
    expected = a.to_a.sort
    out = a._sort_copy_quick_v2
    assert_equal expected, out.to_a
  end

  def test_merge_sorts_large_random_n10k
    srand(20260612)
    a = CArray.float64(10_000) { |i| rand }
    expected = a.to_a.sort
    out = a._sort_copy_merge_v2
    assert_equal expected, out.to_a
  end

  # ---------- edge cases ------------------------------------------------

  def test_quick_empty
    a = CArray.float64(0)
    assert_equal [], a._sort_copy_quick_v2.to_a
  end

  def test_merge_empty
    a = CArray.float64(0)
    assert_equal [], a._sort_copy_merge_v2.to_a
  end

  def test_quick_single
    a = CArray.float64(1) { 42.5 }
    assert_equal [42.5], a._sort_copy_quick_v2.to_a
  end

  def test_merge_single
    a = CArray.float64(1) { 42.5 }
    assert_equal [42.5], a._sort_copy_merge_v2.to_a
  end

  def test_quick_already_sorted_n1000
    a = CArray.float64(1000).seq
    assert_equal a.to_a, a._sort_copy_quick_v2.to_a
  end

  def test_merge_already_sorted_n1000
    # Tests the rev4 single-compare sorted-skip improvement: when left tail
    # <= right head every merge, the inner loop is skipped via memcpy.
    a = CArray.float64(1000).seq
    assert_equal a.to_a, a._sort_copy_merge_v2.to_a
  end

  def test_quick_reverse_sorted_n1000
    a = CArray.float64(1000).seq
    rev = CArray.float64(1000) { |i| a[999 - i] }
    assert_equal a.to_a, rev._sort_copy_quick_v2.to_a
  end

  def test_merge_reverse_sorted_n1000
    a = CArray.float64(1000).seq
    rev = CArray.float64(1000) { |i| a[999 - i] }
    assert_equal a.to_a, rev._sort_copy_merge_v2.to_a
  end

  def test_quick_all_equal
    a = CArray.float64(100) { 3.14 }
    assert_equal Array.new(100, 3.14), a._sort_copy_quick_v2.to_a
  end

  def test_merge_all_equal
    a = CArray.float64(100) { 3.14 }
    assert_equal Array.new(100, 3.14), a._sort_copy_merge_v2.to_a
  end

  # ---------- size sweep across insertion threshold + merge widths ------

  def test_quick_size_sweep
    # Cover sizes around boundaries: < insertion threshold (16), small,
    # boundary values for merge widths (powers of 2), tail-not-power-of-2.
    [0, 1, 2, 15, 16, 17, 32, 33, 63, 64, 100, 127, 128, 255, 1023, 1024].each do |n|
      a = CArray.float64(n) { |i| ((i * 97 + 13) % 1000).to_f }
      assert_equal a.to_a.sort, a._sort_copy_quick_v2.to_a, "n=#{n}"
    end
  end

  def test_merge_size_sweep
    [0, 1, 2, 15, 16, 17, 32, 33, 63, 64, 100, 127, 128, 255, 1023, 1024].each do |n|
      a = CArray.float64(n) { |i| ((i * 97 + 13) % 1000).to_f }
      assert_equal a.to_a.sort, a._sort_copy_merge_v2.to_a, "n=#{n}"
    end
  end

  # ---------- stability (= mergesort only, quicksort is intentionally not) ----

  def test_merge_stable_alternating_duplicates
    # AC5: alternating [1, 2, 1, 2, ...] -- stable sort preserves
    # original order within each equal-key run.
    n = 100
    a = CArray.float64(n) { |i| (i % 2 == 0) ? 1.0 : 2.0 }
    out = a._sort_copy_merge_v2
    # First half should be 1.0 (= original even indices), second half 2.0
    # (= original odd indices), each contiguous.
    assert_equal Array.new(n / 2, 1.0) + Array.new(n / 2, 2.0), out.to_a
  end

  # ---------- non-mutation ----------------------------------------------

  def test_quick_does_not_mutate_input
    a = CArray.float64(50).seq.shuffle!
    snapshot = a.to_a
    a._sort_copy_quick_v2
    assert_equal snapshot, a.to_a
  end

  def test_merge_does_not_mutate_input
    a = CArray.float64(50).seq.shuffle!
    snapshot = a.to_a
    a._sort_copy_merge_v2
    assert_equal snapshot, a.to_a
  end

  # ---------- argument validation ---------------------------------------

  def test_quick_rejects_complex
    # P.2 generic 化以降、ALL_NUMERIC accept。complex / object / bool は依然 reject。
    a = CArray.cmplx128(10).seq
    assert_raise(TypeError) { a._sort_copy_quick_v2 }
  end

  def test_merge_rejects_complex
    a = CArray.cmplx128(10).seq
    assert_raise(TypeError) { a._sort_copy_merge_v2 }
  end

  def test_quick_rejects_2d
    a = CArray.float64(3, 4).seq
    assert_raise(ArgumentError) { a._sort_copy_quick_v2 }
  end

  def test_merge_rejects_2d
    a = CArray.float64(3, 4).seq
    assert_raise(ArgumentError) { a._sort_copy_merge_v2 }
  end

end

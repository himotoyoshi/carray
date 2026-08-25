# MEMO_GALAPAGOS_ESCAPE.md 2026-05-23: reshape auto-infer placeholder
# changed from `false` (galapagos) to `-1` (NumPy-compatible) in 3.0.
# `false` is **completely removed** (fail-fast, no deprecation alias) —
# in-repo usage was zero, so a clean break in 3.0 lets users migrate
# early.  Passing `false` now raises (NUM2SIZE rejects a non-numeric).

require 'test/unit'
require 'carray'

class TestReshapeMinusOnePlaceholder < Test::Unit::TestCase

  # ---- new -1 placeholder ----

  def test_minus_one_at_end
    a = CArray.int32(2, 6).seq
    b = a.reshape(3, -1)
    assert_equal [3, 4], b.dim.to_a
  end

  def test_minus_one_at_start
    a = CArray.int32(2, 6).seq
    b = a.reshape(-1, 4)
    assert_equal [3, 4], b.dim.to_a
  end

  def test_minus_one_middle_three_dim
    a = CArray.int32(2, 3, 4).seq
    b = a.reshape(2, -1, 4)
    assert_equal [2, 3, 4], b.dim.to_a
  end

  def test_flatten_via_minus_one
    a = CArray.int32(2, 3, 4).seq
    b = a.reshape(-1)
    assert_equal [24], b.dim.to_a
    assert_equal a.to_a.flatten, b.to_a
  end

  def test_minus_one_combined_with_nil_mirror
    a = CArray.int32(3, 4, 5).seq
    b = a.reshape(nil, -1)
    # nil mirrors source axis 0 (=3), -1 absorbs the rest (4*5=20).
    assert_equal [3, 20], b.dim.to_a
  end

  # ---- errors ----

  def test_two_minus_one_raises
    a = CArray.int32(12).seq
    assert_raise(RuntimeError) { a.reshape(-1, -1) }
  end

  def test_unresolvable_minus_one_raises
    a = CArray.int32(12).seq  # 12 elements
    # 5 * x = 12 has no integer solution.
    assert_raise(RuntimeError) { a.reshape(5, -1) }
  end

  def test_view_shares_data
    a = CArray.int32(2, 6).seq
    b = a.reshape(3, -1)
    b[0, 0] = 999
    assert_equal 999, a[0, 0]
  end

  # ---- legacy `false` placeholder is removed in 3.0 (fail-fast) ----

  def test_false_raises_in_3_0
    # Pre-3.0 accepted `false` as the auto-infer placeholder; 3.0 removes
    # it entirely.  No deprecation warning, no silent acceptance — passing
    # `false` now raises (NUM2SIZE rejects FalseClass).
    a = CArray.int32(2, 6).seq
    assert_raise(TypeError, ArgumentError) { a.reshape(3, false) }
  end

  def test_true_also_rejected
    # Symmetric sanity check: `true` was never accepted.
    a = CArray.int32(2, 6).seq
    assert_raise(TypeError, ArgumentError) { a.reshape(3, true) }
  end

  # ---- numeric -1 (not a placeholder for dim, but for actual values) ----

  def test_reshape_preserves_negative_values_in_array
    # -1 placeholder only applies to *shape arguments*; the data array
    # itself can contain -1 freely.
    a = CArray.int32(4) { |(i)| i - 2 }   # [-2, -1, 0, 1]
    b = a.reshape(2, 2)
    assert_equal [[-2, -1], [0, 1]], b.to_a
  end
end

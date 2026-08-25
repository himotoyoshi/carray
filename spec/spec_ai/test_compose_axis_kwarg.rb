# bind / merge axis: kwarg signature (= 3.0 breaking).
#
# bind / merge accept `axis:` keyword instead of the previous positional
# `at` argument.  Defaults are both `axis: 0` (= K outermost, matching
# the rest of the compose family and np.stack / np.concatenate).
#
# - bind(list, axis: 0, data_type: nil)
# - merge(list, axis: 0, data_type: nil)
#
# composite / combine still use positional `at` (deferred to a separate
# phase per user direction).

require 'test/unit'
require 'carray'

class TestComposeAxisKwarg < Test::Unit::TestCase

  def setup
    @a = CArray.float64(3, 4) { |i, j| i * 10 + j }
    @b = CArray.float64(3, 4) { |i, j| 100 + i * 10 + j }
    @c = CArray.float64(3, 4) { |i, j| 200 + i * 10 + j }
  end

  # ---------------- bind: axis: kwarg ----------------

  def test_bind_default_axis_zero
    v = CArray.meld([@a, @b, @c])
    # default axis: 0 (= extend axis 0 of parent shape (3, 4) by K=3 → (9, 4))
    assert_equal [9, 4], v.shape
  end

  def test_bind_axis_positive
    v = CArray.meld([@a, @b, @c], axis: 1)
    assert_equal [3, 12], v.shape
  end

  def test_bind_axis_negative
    v = CArray.meld([@a, @b, @c], axis: -1)
    assert_equal [3, 12], v.shape
  end

  def test_bind_positional_now_rejected
    # 3.0 breaking: positional `at` no longer accepted.
    assert_raise(ArgumentError) { CArray.meld([@a, @b, @c], 0) }
    assert_raise(ArgumentError) { CArray.meld([@a, @b, @c], 1) }
  end

  def test_concatenate_axis_kwarg_with_data_type
    # CArray.meld no longer takes data_type: (view semantic requires same
    # dtype at construction).  Auto-cast + explicit data_type: lives on
    # CArray.concatenate (eager).
    v = CArray.concatenate([@a, @b, @c], axis: 0, data_type: :float64)
    assert_equal "float64", v.data_type_name
    assert_equal [9, 4], v.shape
  end

  # ---------------- merge: axis: kwarg ----------------

  def test_merge_default_axis_zero
    v = CArray.stack([@a, @b, @c])
    # default axis: 0 (= K outermost, parent shape (3, 4) + K=3 → (3, 3, 4))
    assert_equal [3, 3, 4], v.shape
    assert_kind_of CAStack, v
    assert_equal 0, v.k_axis
  end

  def test_merge_axis_mid
    v = CArray.stack([@a, @b, @c], axis: 1)
    assert_equal [3, 3, 4], v.shape
    assert_equal 1, v.k_axis
  end

  def test_merge_axis_innermost_explicit
    v = CArray.stack([@a, @b, @c], axis: 2)
    assert_equal [3, 4, 3], v.shape
    assert_equal 2, v.k_axis
  end

  def test_merge_axis_negative_one
    v = CArray.stack([@a, @b, @c], axis: -1)
    # parent_ndim = 2, valid insertion positions [0, 2]; -1 → 2 (innermost)
    assert_equal [3, 4, 3], v.shape
    assert_equal 2, v.k_axis
  end

  def test_merge_positional_now_rejected
    # 3.0 breaking: positional `at = -1` default removed.  CArray.stack
    # takes exactly one positional (the list) + axis: kwarg.  Extra
    # positional args raise ArgumentError ("wrong number of arguments").
    assert_raise(ArgumentError) { CArray.stack([@a, @b, @c], 0) }
    assert_raise(ArgumentError) { CArray.stack([@a, @b, @c], -1) }
  end

  def test_merge_axis_out_of_range
    err = assert_raise(ArgumentError) { CArray.stack([@a, @b, @c], axis: 3) }
    assert_match(/stack: axis 3 out of range for ndim 3/, err.message)
  end

  def test_merge_default_changed_to_zero
    # 3.0 breaking: default was `at: -1` (= K innermost).  Now `axis: 0`
    # (= K outermost).  This test pins the new default and the breaking
    # narrative.
    v = CArray.stack([@a, @b, @c])
    assert_equal 0, v.k_axis
    refute_equal 2, v.k_axis    # would be 2 under old `at: -1` default
  end

  # ---------------- correctness round-trip ----------------

  def test_bind_default_values_correct
    v = CArray.meld([@a, @b, @c]).to_ca
    # axis: 0 default → row 0 = a[0,:], row 3 = b[0,:], row 6 = c[0,:]
    assert_equal 0.0,   v[0, 0]
    assert_equal 100.0, v[3, 0]
    assert_equal 200.0, v[6, 0]
  end

  def test_merge_default_values_correct
    v = CArray.stack([@a, @b, @c]).to_ca
    # axis: 0 default → v[0, i, j] = a[i, j], v[1, i, j] = b[i, j], ...
    assert_equal 0.0,   v[0, 0, 0]
    assert_equal 100.0, v[1, 0, 0]
    assert_equal 200.0, v[2, 0, 0]
    assert_equal 23.0,  v[0, 2, 3]
    assert_equal 123.0, v[1, 2, 3]
  end
end

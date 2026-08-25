# CArray.normalize_axis class method (= N.2 follow-on to the K_AXIS phase).
#
# The class method `CArray.normalize_axis(axis, ndim, name=nil)` is the
# self-independent variant of the existing instance method
# `CArray#normalize_axis(axis, name=nil)`.  It validates `axis` against an
# explicit `ndim` (range [0, ndim)), supporting:
#   - class-method contexts (no `self` available)
#   - insertion positions (= valid [0, old_ndim] inclusive); pass
#     `old_ndim + 1` as `ndim` so the half-open [0, ndim) check matches.

require 'test/unit'
require 'carray'

class TestNormalizeAxisClassMethod < Test::Unit::TestCase

  # ---------------- existing-axis range [0, ndim) ----------------

  def test_class_method_positive_axis
    assert_equal 0, CArray.normalize_axis(0, 3)
    assert_equal 1, CArray.normalize_axis(1, 3)
    assert_equal 2, CArray.normalize_axis(2, 3)
  end

  def test_class_method_negative_axis
    assert_equal 2, CArray.normalize_axis(-1, 3)
    assert_equal 1, CArray.normalize_axis(-2, 3)
    assert_equal 0, CArray.normalize_axis(-3, 3)
  end

  def test_class_method_out_of_range_positive_raises
    err = assert_raise(ArgumentError) { CArray.normalize_axis(3, 3) }
    assert_match(/axis 3 out of range for ndim 3/, err.message)
  end

  def test_class_method_out_of_range_negative_raises
    err = assert_raise(ArgumentError) { CArray.normalize_axis(-4, 3) }
    assert_match(/axis -4 out of range for ndim 3/, err.message)
  end

  def test_class_method_name_in_error_message
    err = assert_raise(ArgumentError) { CArray.normalize_axis(5, 3, "myop") }
    assert_match(/^myop: axis 5 out of range for ndim 3/, err.message)
  end

  def test_class_method_default_name_is_axis
    err = assert_raise(ArgumentError) { CArray.normalize_axis(5, 3) }
    assert_match(/^axis: axis 5 out of range for ndim 3/, err.message)
  end

  # ---------------- insertion-position pattern ----------------

  def test_insertion_at_end_with_negative_one
    # parent_ndim = 2, insertion valid [0, 2] inclusive -> pass ndim=3
    assert_equal 2, CArray.normalize_axis(-1, 3, "merge")
    assert_equal 2, CArray.normalize_axis(2, 3, "merge")
  end

  def test_insertion_at_beginning
    assert_equal 0, CArray.normalize_axis(0, 3, "merge")
    assert_equal 0, CArray.normalize_axis(-3, 3, "merge")
  end

  def test_insertion_out_of_range
    # parent_ndim = 2 -> valid insertion positions [0, 2]; 3 is OOR
    err = assert_raise(ArgumentError) { CArray.normalize_axis(3, 3, "merge") }
    assert_match(/merge: axis 3 out of range for ndim 3/, err.message)
  end

  # ---------------- equivalence with instance method ----------------

  def test_equivalent_to_instance_method_when_ndim_matches
    ca = CArray.int32(4, 5, 6) { 0 }
    [-3, -2, -1, 0, 1, 2].each do |ax|
      assert_equal ca.normalize_axis(ax),
                   CArray.normalize_axis(ax, ca.ndim),
                   "axis #{ax}"
    end
  end

  # ---------------- compose.rb migration round-trip ----------------
  #
  # bind / merge / composite were migrated to use this helper.  Verify
  # negative axes still resolve correctly through the new code path.

  def test_compose_family_negative_axis_through_new_helper
    a = CArray.int32(2, 3) { |i, j| i * 10 + j }
    b = CArray.int32(2, 3) { |i, j| 100 + i * 10 + j }

    # merge at=-1 = innermost = k_axis 2 for parent_ndim=2
    m = CArray.stack([a, b], axis: -1)
    assert_equal 2, m.k_axis
    assert_equal [2, 3, 2], m.shape

    # bind at=-1 = parent's last axis (= parent_ndim-1=1)
    v = CArray.meld([a, b], axis: -1)
    assert_equal [2, 6], v.shape
  end

  def test_compose_family_out_of_range_uses_kernel_message
    a = CArray.int32(2, 3) { 0 }
    b = CArray.int32(2, 3) { 0 }

    err = assert_raise(ArgumentError) { CArray.stack([a, b], axis: 3) }
    assert_match(/stack: axis 3 out of range for ndim 3/, err.message)

    err = assert_raise(ArgumentError) { CArray.meld([a, b], axis: 2) }
    assert_match(/meld: axis 2 out of range for ndim 2/, err.message)
  end
end

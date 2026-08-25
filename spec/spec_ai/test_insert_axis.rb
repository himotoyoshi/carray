# ----------------------------------------------------------------------------
#
#  spec_ai/test_insert_axis.rb
#
#  Tests for CArray#insert_axis(*axes): inserts length-1 axes before the
#  given source axes (source frame; a position names the existing axis the
#  new axis goes before, ndim = append at end, duplicates stack).  The bare
#  size-1 primitive is __insert_axis_size1__ (ext/ca_obj_refer.c); the
#  user-facing insert_axis lives in lib/carray/basics.rb.  The repeat:
#  keyword is covered in test_insert_axis_repeat.rb.
#
# ----------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestInsertAxis < Test::Unit::TestCase

  # ---- basic single-axis insertion --------------------------------------

  def test_insert_head
    a = CArray.int32(2, 3).seq!
    v = a.insert_axis(0)
    assert_equal [1, 2, 3], v.dim
    assert_equal 3, v.ndim
  end

  def test_insert_tail
    a = CArray.int32(2, 3).seq!
    v = a.insert_axis(-1)
    assert_equal [2, 3, 1], v.dim
  end

  def test_insert_middle
    a = CArray.int32(2, 3).seq!
    v = a.insert_axis(1)
    assert_equal [2, 1, 3], v.dim
  end

  def test_insert_zero_arg_raises
    # inserting nothing is a caller error, not a silent identity.
    a = CArray.int32(2, 3).seq!
    assert_raise(ArgumentError) { a.insert_axis }
  end

  # ---- multi-axis insertion --------------------------------------------

  def test_insert_two_axes_head_and_tail
    a = CArray.int32(2, 3).seq!
    # before axis 0 and at the end (gap 2 == -1)
    v = a.insert_axis(0, -1)
    assert_equal [1, 2, 3, 1], v.dim
  end

  def test_insert_two_axes_middle_and_tail
    a = CArray.int32(2, 3).seq!
    # before axis 1 and at the end (gap 2)
    v = a.insert_axis(1, 2)
    assert_equal [2, 1, 3, 1], v.dim
  end

  def test_insert_three_axes
    a = CArray.int32(2, 3).seq!
    # before each source axis and at the end -> [1, 2, 1, 3, 1]
    v = a.insert_axis(0, 1, 2)
    assert_equal [1, 2, 1, 3, 1], v.dim
  end

  def test_insert_stacked_at_one_gap
    a = CArray.int32(2, 3).seq!
    # two axes before axis 0 (duplicate position = stack)
    v = a.insert_axis(0, 0)
    assert_equal [1, 1, 2, 3], v.dim
  end

  def test_insert_two_negative_axes
    a = CArray.int32(2, 3).seq!
    # -1 -> gap 2 (end), -2 -> gap 1 (before last axis) -> [2, 1, 3, 1]
    v = a.insert_axis(-1, -2)
    assert_equal [2, 1, 3, 1], v.dim
  end

  # ---- semantics: zero-copy + data preservation -------------------------

  def test_view_shares_data
    a = CArray.int32(3) { |i| i * 100 }
    v = a.insert_axis(0)
    assert_equal 0,   v[0, 0]
    assert_equal 100, v[0, 1]
    assert_equal 200, v[0, 2]
  end

  def test_view_writeback_to_parent
    a = CArray.int32(3).seq!
    v = a.insert_axis(0)
    v[0, 1] = 999
    assert_equal 999, a[1]
  end

  # ---- error cases ------------------------------------------------------

  def test_axis_out_of_range
    a = CArray.int32(2, 3)   # gaps are 0..2 (ndim = 2)
    assert_raise(ArgumentError) { a.insert_axis(3) }    # 3 > ndim
    assert_raise(ArgumentError) { a.insert_axis(-4) }   # -4 + 3 = -1 < 0
  end

  # ---- broadcast use case (= the original order method motivation) ------

  def test_broadcast_via_insert_axis
    # The classic motivating use: reduce result needs an axis re-inserted
    # before broadcasting back against the original shape.
    a = CArray.int32(2, 4) { |i| i }   # shape [2, 4]
    col_sums = a.sum(axis: 1)            # shape [2]
    bcasted  = col_sums.insert_axis(1)   # shape [2, 1]
    # bcasted broadcasts cleanly against a: a - bcasted is shape [2, 4]
    centered = a - bcasted
    assert_equal [2, 4], centered.dim
  end

end

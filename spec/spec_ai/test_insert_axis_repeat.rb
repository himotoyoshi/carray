# test_insert_axis_repeat.rb
#
# Tests for CArray#insert_axis with the repeat: keyword.
#
#   repeat: 1 / nil / omitted  -> size-1 axis (CARefer; no assignment broadcast)
#   repeat: N (Integer > 1)    -> bound repeat (CARepeat; read-only)
#   repeat: :*                 -> unbound repeat (CAUnboundRepeat; binds on store)
#   mixed                      -> two-stage composition (bound then unbound)

require 'test/unit'
$LOAD_PATH.unshift File.expand_path('../../ext', __dir__)
$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'carray'

class TestInsertAxisRepeat < Test::Unit::TestCase

  def setup
    @a = CArray.int32(3, 4).seq   # 0..11
  end

  # ---------- default / size-1 ----------

  def test_default_single
    assert_equal [1, 3, 4], @a.insert_axis(0).shape
  end

  def test_default_multiple
    # before axis 0 and before axis 1
    assert_equal [1, 3, 1, 4], @a.insert_axis(0, 1).shape
  end

  def test_default_stacked_at_one_gap
    # duplicate position stacks several axes before that source axis
    assert_equal [1, 1, 3, 4], @a.insert_axis(0, 0).shape
    assert_equal [3, 4, 1, 1], @a.insert_axis(2, 2).shape
  end

  def test_default_negative_position
    assert_equal [3, 4, 1], @a.insert_axis(-1).shape
  end

  def test_repeat_1_is_size1
    assert_equal [1, 3, 4], @a.insert_axis(0, repeat: 1).shape
  end

  def test_size1_data_matches_original
    v = @a.insert_axis(0)
    assert_equal @a.to_a, v[0, nil, nil].to_a
  end

  def test_size1_does_not_broadcast_on_assignment
    # size-1 is a plain reference; a 12-element source into a 12-cell target
    # is a flat copy, but it must NOT stretch to a larger target.
    t = CArray.int32(5, 3, 4)
    assert_raise(RuntimeError) { t[] = @a.insert_axis(0) }
  end

  def test_empty_positions_raises
    # inserting nothing is a caller error, not a silent no-op.
    assert_raise(ArgumentError) { @a.insert_axis }
    assert_raise(ArgumentError) { @a.insert_axis([]) }
  end

  # ---------- bound repeat (CARepeat) ----------

  def test_bound_front
    v = @a.insert_axis(0, repeat: 5)
    assert_equal [5, 3, 4], v.shape
    assert_equal CARepeat, v.class
    assert_equal @a.to_a, v[0, nil, nil].to_a
    assert_equal @a.to_a, v[4, nil, nil].to_a
  end

  def test_bound_middle
    v = @a.insert_axis(1, repeat: 7)
    assert_equal [3, 7, 4], v.shape
    assert_equal @a.to_a, v[nil, 0, nil].to_a
    assert_equal @a.to_a, v[nil, 6, nil].to_a
  end

  def test_bound_is_read_only
    v = @a.insert_axis(0, repeat: 5)
    assert_raise(RuntimeError) { v[0, 0, 0] = 99 }
  end

  def test_bound_multiple_via_array
    # before axis 0 (repeat 2) and before axis 1 (repeat 5)
    v = @a.insert_axis([0, 1], repeat: [2, 5])
    assert_equal [2, 3, 5, 4], v.shape
  end

  def test_bound_scalar_applies_to_all
    # scalar repeat applies to every inserted axis; two stacked before axis 0
    v = @a.insert_axis(0, 0, repeat: 2)
    assert_equal [2, 2, 3, 4], v.shape
  end

  # ---------- unbound repeat (:*) ----------

  def test_unbound_class_and_shape
    v = @a.insert_axis(0, repeat: :*)
    assert_equal CAUnboundRepeat, v.class
    assert_equal [1, 3, 4], v.shape    # unbound axis reads as size 1
  end

  def test_unbound_binds_on_assignment
    v = @a.insert_axis(0, repeat: :*)
    t = CArray.int32(6, 3, 4)
    t[] = v
    assert_equal @a.to_a, t[0, nil, nil].to_a
    assert_equal @a.to_a, t[5, nil, nil].to_a
  end

  def test_unbound_multiple
    v = @a.insert_axis(0, 1, repeat: :*)
    assert_equal CAUnboundRepeat, v.class
    assert_equal [1, 3, 1, 4], v.shape
  end

  # ---------- mixed bound + unbound ----------

  def test_mixed_unbound_and_bound
    # before axis 0: unbound; before axis 1: bound to 5
    v = @a.insert_axis([0, 1], repeat: [:*, 5])
    assert_equal CAUnboundRepeat, v.class
    assert_equal [1, 3, 5, 4], v.shape    # unbound, orig0, bound5, orig1

    t = CArray.int32(6, 3, 5, 4)
    t[] = v
    # bound axis is concrete (5); unbound axis (front) binds to 6
    assert_equal @a.to_a, t[0, nil, 0, nil].to_a
    assert_equal @a.to_a, t[5, nil, 4, nil].to_a
  end

  def test_mixed_bound_unbound_size1
    # before axis 0: bound 6; before axis 1: unbound; before end: size-1
    v = @a.insert_axis([0, 1, 2], repeat: [6, :*, 1])
    assert_equal [6, 3, 1, 4, 1], v.shape
  end

  # ---------- errors ----------

  def test_repeat_array_length_mismatch_raises
    assert_raise(ArgumentError) { @a.insert_axis([0, 1], repeat: [3]) }
  end

  def test_repeat_zero_raises
    assert_raise(ArgumentError) { @a.insert_axis(0, repeat: 0) }
  end

  def test_repeat_bad_value_raises
    assert_raise(ArgumentError) { @a.insert_axis(0, repeat: :foo) }
  end

  def test_duplicate_position_with_distinct_repeats
    # two axes before source axis 0, in argument order: bound 2 then unbound
    v = @a.insert_axis(0, 0, repeat: [2, :*])
    assert_equal CAUnboundRepeat, v.class
    assert_equal [2, 1, 3, 4], v.shape    # bound2, unbound, orig0, orig1
    t = CArray.int32(2, 7, 3, 4)
    t[] = v
    assert_equal @a.to_a, t[0, 0, nil, nil].to_a
    assert_equal @a.to_a, t[1, 6, nil, nil].to_a
  end

  def test_out_of_range_position_raises
    assert_raise(ArgumentError) { @a.insert_axis(9) }   # gap 9 > ndim
  end

  def test_nil_in_repeat_array_raises
    # nil is not a valid per-axis repeat; use 1 for a size-1 axis.
    assert_raise(ArgumentError) { @a.insert_axis([0, 1], repeat: [nil, 3]) }
  end

end

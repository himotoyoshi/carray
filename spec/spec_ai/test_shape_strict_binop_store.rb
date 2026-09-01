# test_shape_strict_binop_store.rb
#
# A source that claims a shape is matched by shape; one that claims none --
# a Ruby Array, or a 1-D CArray -- is still poured in by element count.
#
#   assignment : the destination owns the shape, the source supplies values
#   operation  : both operands are equally authoritative, so shapes must agree
#
# The escape on either side is #flatten, which returns a view.

require 'test/unit'
$LOAD_PATH.unshift File.expand_path('../../ext', __dir__)
$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'carray'

class TestShapeStrictStore < Test::Unit::TestCase

  # ---------- shapes both sides claim must agree ----------

  def test_cross_shape_source_is_refused
    t = CArray.int32(3, 2)
    assert_raise(RuntimeError) { t[] = CArray.int32(2, 3).seq }
  end

  def test_flatten_is_the_escape
    t = CArray.int32(3, 2)
    t[] = CArray.int32(2, 3).seq.flatten
    assert_equal [[0, 1], [2, 3], [4, 5]], t.to_a
  end

  # ---------- a size-1 axis carries no shape information ----------

  def test_trailing_size1_axis_on_the_destination
    t = CArray.int32(2, 3, 1)
    t[] = CArray.int32(2, 3).seq
    assert_equal [[[0], [1], [2]], [[3], [4], [5]]], t.to_a
  end

  def test_leading_size1_axis_on_the_destination
    t = CArray.int32(1, 2, 3)
    t[] = CArray.int32(2, 3).seq
    assert_equal [[[0, 1, 2], [3, 4, 5]]], t.to_a
  end

  def test_size1_axes_on_opposite_sides
    # equal counts, so this is a squeeze match and never enters broadcast
    t = CArray.int32(1, 3)
    t[] = CArray.int32(3, 1).seq
    assert_equal [[0, 1, 2]], t.to_a
  end

  # ---------- a 1-D side claims no shape ----------

  def test_flat_source_into_a_shaped_destination
    t = CArray.int32(3, 2)
    t[] = CArray.int32(6).seq
    assert_equal [[0, 1], [2, 3], [4, 5]], t.to_a
  end

  def test_shaped_source_into_a_flat_destination
    t = CArray.int32(6)
    t[] = CArray.int32(3, 2).seq
    assert_equal [0, 1, 2, 3, 4, 5], t.to_a
  end

  def test_flat_view_of_a_view_takes_a_shaped_payload
    c = CArray.int32(4, 3).seq
    c.grid(nil, nil)[nil] = CArray.int32(4, 3).seq * -1
    assert_equal(-11, c[3, 2])
  end

  # ---------- a smaller source is repeated ----------

  def test_size1_axis_stretches_to_the_destination
    t = CArray.int32(5, 3, 4)
    row = CArray.int32(3, 4).seq
    t[] = row[:_, nil, nil]
    5.times { |i| assert_equal row.to_a, t[i, nil, nil].to_a }
  end

  def test_stretch_on_an_inner_axis
    t = CArray.int32(3, 3)
    t[] = CArray.int32(3, 1).seq * 10
    assert_equal [[0, 0, 0], [10, 10, 10], [20, 20, 20]], t.to_a
  end

  def test_stretch_is_one_sided
    # the source may be repeated; the container never grows
    t = CArray.int32(1, 3, 4)
    assert_raise(RuntimeError) { t[] = CArray.int32(5, 3, 4).seq }
  end

  def test_larger_source_is_refused
    t = CArray.int32(3, 4)
    assert_raise(RuntimeError) { t[] = CArray.int32(5, 4).seq }
  end

  # ---------- lanes left alone ----------

  def test_ruby_array_is_still_poured_in_by_count
    t = CArray.int32(3, 2)
    t[] = [1, 2, 3, 4, 5, 6]
    assert_equal [[1, 2], [3, 4], [5, 6]], t.to_a
    t[] = [[1, 2, 3], [4, 5, 6]]          # nesting is deliberately flattened
    assert_equal [[1, 2], [3, 4], [5, 6]], t.to_a
  end

  def test_scalar_still_reaches_every_cell
    t = CArray.int32(3, 2)
    t[] = 7
    assert_equal [[7, 7], [7, 7], [7, 7]], t.to_a
  end

  def test_unbound_repeat_is_untouched
    t = CArray.int32(5, 3, 4)
    row = CArray.int32(3, 4).seq
    t[] = row[:*, nil, nil]
    5.times { |i| assert_equal row.to_a, t[i, nil, nil].to_a }
  end
end

class TestShapeStrictBinop < Test::Unit::TestCase

  def test_cross_shape_operands_are_refused
    assert_raise(ArgumentError) { CArray.int32(3, 2).seq + CArray.int32(2, 3).seq }
  end

  def test_the_answer_no_longer_depends_on_operand_order
    a = CArray.int32(3, 2).seq
    b = CArray.int32(6).seq
    assert_raise(ArgumentError) { a + b }
    assert_raise(ArgumentError) { b + a }
  end

  def test_a_size1_axis_is_not_enough_across_ndim
    assert_raise(ArgumentError) do
      CArray.int32(2, 3, 1).seq + CArray.int32(2, 3).seq
    end
  end

  def test_flatten_on_both_sides_is_the_escape
    a = CArray.int32(3, 2).seq
    b = CArray.int32(2, 3).seq
    assert_equal [6], (a.flatten + b.flatten).shape
  end

  def test_comparison_and_ternary_follow_the_same_rule
    a = CArray.float64(3, 2).seq
    b = CArray.float64(2, 3).seq
    assert_raise(ArgumentError) { a.eq(b) }
    assert_raise(ArgumentError) { a.fma(b, a) }
  end

  def test_lazy_answers_like_eager
    a = CArray.int32(3, 2).seq
    b = CArray.int32(2, 3).seq
    assert_raise(ArgumentError) { (a.lazy + b).to_ca }
    assert_raise(ArgumentError) { (a.lazy.eq(b)).to_ca }
  end

  def test_one_element_array_states_a_shape_on_both_paths
    a = CArray.int32(3, 2).seq
    one = CArray.int32(1).seq
    assert_raise(ArgumentError) { a + one }
    assert_raise(ArgumentError) { (a.lazy + one).to_ca }
  end

  # ---------- what still broadcasts ----------

  def test_size1_axes_broadcast_at_equal_ndim
    a = CArray.int32(3, 2).seq
    assert_equal [[0, 1], [2, 3], [4, 5]], (a + CArray.int32(1, 1)).to_a
    assert_equal [3, 2], (a + CArray.int32(3, 1).seq).shape
  end

  def test_scalars_are_exempt
    a = CArray.int32(3, 2).seq
    assert_equal [3, 2], (a + 7).shape
    assert_equal [3, 2], (a + CScalar.int32.tap { |s| s[0] = 7 }).shape
  end

  def test_unbound_repeat_is_untouched
    base = CArray.int32(5, 3, 4).seq
    row  = CArray.int32(3, 4).seq
    assert_equal [5, 3, 4], (base + row[:*, nil, nil]).shape
  end
end

class TestShapeStrictInPlace < Test::Unit::TestCase

  # self is the write target, so the destination rule applies

  def test_flat_operand_is_accepted
    a = CArray.int32(3, 2).seq
    a.add!(CArray.int32(6).seq)
    assert_equal [[0, 2], [4, 6], [8, 10]], a.to_a
  end

  def test_cross_shape_operand_is_refused
    a = CArray.int32(3, 2).seq
    assert_raise(RuntimeError) { a.add!(CArray.int32(2, 3).seq) }
  end

  def test_smaller_operand_is_repeated
    a = CArray.int32(3, 3).seq
    a.add!(CArray.int32(3, 1).seq * 10)
    assert_equal [[0, 1, 2], [13, 14, 15], [26, 27, 28]], a.to_a
  end

  def test_ternary_in_place_follows_the_same_rule
    a = CArray.float64(3, 2).seq
    assert_raise(RuntimeError) { a.fma!(CArray.float64(2, 3).seq, a.copy) }
  end
end

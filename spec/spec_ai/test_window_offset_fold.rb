require "test/unit"
require_relative "../../lib/carray"

# Folding a small window by offset instead of by anchor.
#
# `windows(...).sum` and its siblings fold the window axes, which are the
# innermost ones, so the core pays a per-fiber setup once per output cell.  For
# a small window the same fold runs faster the other way round -- one pass per
# window offset, accumulated into the result.  The two paths must agree, and
# the delegating one must still be taken wherever the accumulation cannot
# answer: a masked source, a min_count, a window wider than 5 on any axis, or
# an operation with no identity to accumulate from.

class TestWindowOffsetFold < Test::Unit::TestCase

  # What the delegating path returns -- the expression this optimisation
  # replaces, written out so the test does not depend on which path ran.
  def delegated (iterator, op, **kw)
    axes = iterator.instance_variable_get(:@window_axes)
    iterator.sliding_view.send(op, axis: axes, **kw)
  end

  def assert_agrees (iterator, op, **kw)
    got  = iterator.send(op, **kw)
    want = delegated(iterator, op, **kw)
    assert_equal want.data_type, got.data_type
    assert_equal want.dim, got.dim
    if want.float?
      scale = want.abs.max
      tolerance = (scale.zero? ? 1e-300 : scale * 1e-12)
      assert_operator (got - want).abs.max, :<=, tolerance
    else
      assert_equal want.to_a, got.to_a
    end
    assert_equal want.count_masked, got.count_masked
  end

  # ---- the two paths agree ----------------------------------------------

  data("1-D" => [400], "2-D" => [40, 50], "3-D" => [12, 14, 16])
  def test_agrees_across_ranks (shape)
    srand(11)
    source = CArray.float64(*shape) { rand * 50 }
    [1, 2].each do |half|                      # widths 3 and 5: accumulated
      ranges = Array.new(shape.size) { -half..half }
      [:skip, :nearest, :truncate].each do |bounds|
        iterator = source.windows(*ranges, bounds: bounds)
        [:sum, :prod, :min, :max].each { |op| assert_agrees(iterator, op) }
      end
    end
  end

  data("uint8" => :uint8, "int32" => :int32, "float32" => :float32)
  def test_agrees_across_data_types (type)
    srand(12)
    source = CArray.send(type, 40, 50)
    source[] = CArray.float64(40, 50) { rand * 20 }.send(type)
    iterator = source.windows(-1..1, -1..1)
    [:sum, :prod, :min, :max].each { |op| assert_agrees(iterator, op) }
  end

  def test_agrees_for_boolean
    srand(13)
    source = CArray.boolean(40, 50)
    800.times { source[rand(40), rand(50)] = true }
    [:skip, :nearest, :truncate].each do |bounds|
      iterator = source.windows(-1..1, -1..1, bounds: bounds)
      [:all, :any, :sum, :min, :max].each { |op| assert_agrees(iterator, op) }
    end
  end

  def test_agrees_for_odd_shaped_windows
    srand(14)
    source = CArray.float64(20, 25) { rand }
    [[0..0, 0..0], [-2..0, -2..0], [0..2, 0..2],
     [-1..1, -2..2], [0..0, -1..1]].each do |ranges|
      [:skip, :nearest, :truncate].each do |bounds|
        iterator = source.windows(*ranges, bounds: bounds)
        [:sum, :min, :max, :prod].each { |op| assert_agrees(iterator, op) }
      end
    end
  end

  def test_agrees_with_a_constant_margin
    srand(15)
    source = CArray.float64(30, 30) { rand }
    iterator = source.windows(-1..1, -1..1, fill_value: 7.0)
    [:sum, :min, :max].each { |op| assert_agrees(iterator, op) }
  end

  # ---- and the delegating path is still taken where it must be ----------

  def test_masked_source_still_delegates
    srand(16)
    source = CArray.float64(30, 30) { rand }
    source[3, 4] = UNDEF
    source[10, 10] = UNDEF
    iterator = source.windows(-1..1, -1..1)
    [:sum, :min, :max].each do |op|
      assert_nil iterator.send(:fold_by_offset, op, nil)
      assert_agrees(iterator, op)
    end
  end

  def test_min_count_still_delegates
    source = CArray.float64(30, 30).seq!
    iterator = source.windows(-1..1, -1..1)
    assert_nil iterator.send(:fold_by_offset, :sum, 9)
    assert_agrees(iterator, :sum, min_count: 9)
  end

  def test_a_wide_window_still_delegates
    source = CArray.float64(40, 40).seq!
    assert_nil source.windows(-3..3, -3..3).send(:fold_by_offset, :sum, nil)
    assert_nil source.windows(-1..1, -3..3).send(:fold_by_offset, :sum, nil)
    assert_not_nil source.windows(-2..2, -2..2).send(:fold_by_offset, :sum, nil)
    assert_agrees(source.windows(-3..3, -3..3), :sum)
  end

  def test_operations_without_an_identity_still_delegate
    source = CArray.float64(20, 20).seq!
    iterator = source.windows(-1..1, -1..1)
    [:mean, :variance, :stddev, :minmax, :min_index, :max_index].each do |op|
      assert_nil iterator.send(:fold_by_offset, op, nil)
    end
  end

  # ---- the answers themselves -------------------------------------------

  def test_rolling_sum_by_hand
    source = CArray.float64(6).seq(1)          # [1..6]
    assert_equal [3.0, 6.0, 9.0, 12.0, 15.0, 11.0],
                 source.windows(-1..1).sum.to_a
    assert_equal [1.0, 1.0, 2.0, 3.0, 4.0, 5.0],
                 source.windows(-1..1).min.to_a
    assert_equal [2.0, 3.0, 4.0, 5.0, 6.0, 6.0],
                 source.windows(-1..1).max.to_a
  end

  def test_a_masked_result_is_never_produced_from_an_unmasked_source
    source = CArray.float64(10, 10).seq!
    assert_equal 0, source.windows(-1..1, -1..1).sum.count_masked
  end

end

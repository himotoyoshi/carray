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
    assert_equal want.count_masked, got.count_masked
    assert_equal want.is_masked.to_a, got.is_masked.to_a if want.has_mask?
    # Compare the cells that have a value; a masked one carries no number.
    got_values  = got.has_mask?  ? got.strip_mask(0)  : got
    want_values = want.has_mask? ? want.strip_mask(0) : want
    if want.float?
      scale = want_values.abs.max
      tolerance = (scale.zero? ? 1e-300 : scale * 1e-12)
      assert_operator (got_values - want_values).abs.max, :<=, tolerance
    else
      assert_equal want_values.to_a, got_values.to_a
    end
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
        [:sum, :prod, :min, :max, :mean].each { |op| assert_agrees(iterator, op) }
      end
    end
  end

  data("uint8" => :uint8, "int32" => :int32, "float32" => :float32)
  def test_agrees_across_data_types (type)
    srand(12)
    source = CArray.send(type, 40, 50)
    source[] = CArray.float64(40, 50) { rand * 20 }.send(type)
    iterator = source.windows(-1..1, -1..1)
    [:sum, :prod, :min, :max, :mean].each { |op| assert_agrees(iterator, op) }
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

  # ---- a masked source ---------------------------------------------------

  data("1-D" => [400], "2-D" => [30, 40], "3-D" => [10, 11, 12])
  def test_agrees_with_a_masked_source (shape)
    srand(16)
    source = CArray.float64(*shape) { rand * 10 }
    (source.elements / 20).times { source[rand(source.elements)] = UNDEF }
    [1, 2].each do |half|
      ranges = Array.new(shape.size) { -half..half }
      [:skip, :nearest, :truncate].each do |bounds|
        iterator = source.windows(*ranges, bounds: bounds)
        [:sum, :prod, :min, :max, :mean].each { |op| assert_agrees(iterator, op) }
        [1, 3].each do |wanted|
          assert_agrees(iterator, :sum, min_count: wanted)
          assert_agrees(iterator, :mean, min_count: wanted)
        end
      end
    end
  end

  def test_a_window_that_folds_nothing
    source = CArray.float64(7).seq(1)
    source[2] = UNDEF
    source[3] = UNDEF
    source[4] = UNDEF                        # the window at 3 holds nothing
    iterator = source.windows(-1..1)
    # sum and prod answer with their identity; min, max and mean have none.
    assert_equal 0.0, iterator.sum[3]
    assert_equal 1.0, iterator.prod[3]
    assert_equal UNDEF, iterator.min[3]
    assert_equal UNDEF, iterator.max[3]
    assert_equal UNDEF, iterator.mean[3]
    [:sum, :prod, :min, :max, :mean].each { |op| assert_agrees(iterator, op) }
  end

  def test_a_masked_boolean_source
    srand(17)
    source = CArray.boolean(30, 40)
    400.times { source[rand(30), rand(40)] = true }
    100.times { source[rand(30), rand(40)] = UNDEF }
    [:skip, :nearest].each do |bounds|
      iterator = source.windows(-1..1, -1..1, bounds: bounds)
      [:all, :any, :sum].each { |op| assert_agrees(iterator, op) }
    end
  end

  def test_a_source_masked_everywhere_delegates_for_min_and_max
    source = CArray.float64(10, 10)
    source[] = UNDEF
    iterator = source.windows(-1..1, -1..1)
    [:min, :max].each do |op|
      assert_nil iterator.send(:fold_by_offset, op, nil, nil)
      assert_agrees(iterator, op)
    end
    # sum still has an identity to answer with.
    assert_not_nil iterator.send(:fold_by_offset, :sum, nil, nil)
    assert_agrees(iterator, :sum)
  end

  def test_min_count_is_answered_from_the_same_cell_count
    source = CArray.float64(30, 30).seq!
    [:skip, :nearest].each do |bounds|
      iterator = source.windows(-1..1, -1..1, bounds: bounds)
      assert_not_nil iterator.send(:fold_by_offset, :sum, 9, nil)
      [1, 4, 9, 10].each do |wanted|
        [:sum, :mean, :min].each { |op| assert_agrees(iterator, op, min_count: wanted) }
      end
    end
  end

  def test_a_fill_value_replaces_what_min_count_left_undefined
    source = CArray.float64(6).seq(1)
    assert_equal [0.0, 6.0, 9.0, 12.0, 15.0, 0.0],
                 source.windows(-1..1).sum(min_count: 3, fill_value: 0.0).to_a
    iterator = source.windows(-1..1)
    assert_agrees(iterator, :mean, min_count: 3, fill_value: -1.0)
    assert_agrees(iterator, :sum,  min_count: 2, fill_value: 0.0)
  end

  def test_a_partly_covered_window_is_undefined_under_min_count
    source = CArray.float64(6).seq(1)
    # :skip folds 2 cells at either end, 3 in the middle.
    assert_equal [UNDEF, 6.0, 9.0, 12.0, 15.0, UNDEF],
                 source.windows(-1..1).sum(min_count: 3).to_a
    # :nearest fills the margins, so every window holds the whole three.
    assert_equal [4.0, 6.0, 9.0, 12.0, 15.0, 17.0],
                 source.windows(-1..1, bounds: :nearest).sum(min_count: 3).to_a
    assert_equal [UNDEF] * 6,
                 source.windows(-1..1, bounds: :nearest).sum(min_count: 4).to_a
  end

  def test_a_wide_window_still_delegates
    source = CArray.float64(40, 40).seq!
    assert_nil source.windows(-3..3, -3..3).send(:fold_by_offset, :sum, nil, nil)
    assert_nil source.windows(-1..1, -3..3).send(:fold_by_offset, :sum, nil, nil)
    assert_not_nil source.windows(-2..2, -2..2).send(:fold_by_offset, :sum, nil, nil)
    assert_agrees(source.windows(-3..3, -3..3), :sum)
  end

  def test_operations_without_an_identity_still_delegate
    source = CArray.float64(20, 20).seq!
    iterator = source.windows(-1..1, -1..1)
    [:variance, :stddev, :variancep, :stddevp,
     :minmax, :min_index, :max_index].each do |op|
      assert_nil iterator.send(:fold_by_offset, op, nil, nil)
    end
  end

  def test_the_fold_reads_one_type_whatever_the_source_holds
    # Adding across two types runs a different kernel from adding within one,
    # and how much slower that is depends on the pair and the machine.  The
    # buffer is converted once instead, so every source behaves the same.
    [:uint8, :int32, :float32, :float64, :boolean].each do |type|
      source = CArray.new(type, [20, 20])
      iterator = source.windows(-1..1, -1..1)
      [:sum, :min, :max].each do |op|
        base = iterator.send(:offset_fold_base, op)
        assert_equal iterator.send(:offset_fold_data_type, op), base.data_type,
                     "#{type} #{op}"
      end
    end
  end

  # ---- the answers themselves -------------------------------------------

  def test_rolling_sum_by_hand
    source = CArray.float64(6).seq(1)          # [1..6]
    assert_equal [3.0, 6.0, 9.0, 12.0, 15.0, 11.0],
                 source.windows(-1..1).sum.to_a
    # The ends fold two cells, so their mean divides by two, not three.
    assert_equal [1.5, 2.0, 3.0, 4.0, 5.0, 5.5],
                 source.windows(-1..1).mean.to_a
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

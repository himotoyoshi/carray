require "test/unit"
require "carray"

# Reductions answer the same whichever walk the generator picks for the
# source: the column-wise walk over a contiguous buffer honours min_count,
# the position of an extremum is never a masked or NaN cell, and the object
# weighted mean answers UNDEF for a zero weight sum also under keep_axis.
class TestReducePathEdges < Test::Unit::TestCase

  INF = Float::INFINITY
  NAN = Float::NAN

  # (10, 128) is large enough for the column-wise walk; (10, 8) is not.
  def test_min_count_above_the_axis_length
    [[10, 128], [10, 8]].each do |shape|
      a = CArray.float64(*shape).seq!
      %i[sum prod mean min max accumulate].each do |op|
        assert_same UNDEF, a.send(op, axis: 0, min_count: 20)[0], "#{shape} #{op}"
        assert_equal(-1.0, a.send(op, axis: 0, min_count: 20, fill_value: -1)[0], "#{shape} #{op} fill")
        assert_equal a.copy[nil, 0].send(op), a.send(op, axis: 0, min_count: 10)[0], "#{shape} #{op} met"
      end
      b = CArray.boolean(*shape) { 1 }
      assert_same UNDEF, b.count(true, axis: 0, min_count: 20)[0], "#{shape} count"
    end
  end

  def test_min_count_through_a_reshape_and_a_stack
    a = CArray.float64(1280).seq!.reshape(10, 128)
    assert_same UNDEF, a.sum(axis: 0, min_count: 20)[0]
    parts = (0..2).map { CArray.float64(4, 10, 128).seq! }
    assert_same UNDEF, CArray.stack(parts, axis: 2).sum(axis: 1, min_count: 20)[0, 0, 0]
    assert_same UNDEF, CArray.stack(parts, axis: 1).sum(axis: 2, min_count: 20)[0, 0, 0]
    parts = (0..2).map { CArray.float64(4, 10, 6, 128).seq! }
    assert_same UNDEF, CArray.stack(parts, axis: 3).sum(axis: 1, min_count: 20)[0, 0, 0, 0]
    parts = (0..2).map { CArray.float64(10, 128).seq! }
    assert_same UNDEF, CArray.stack(parts, axis: 0).sum(axis: 1, min_count: 20)[0, 0]
  end

  def test_extremum_position_skips_masked_cells
    c = CArray.float64(2) { [1.0, INF] }
    c[0] = UNDEF
    assert_equal 1, c.min_index
    assert_equal 1, c.min_addr
    x = CArray.uint8(20) { 255 }
    x[0] = UNDEF
    assert_equal 1, x.min_index
    y = CArray.uint8(3) { [7, 0, 0] }
    y[0] = UNDEF
    assert_equal 1, y.max_index
    z = CArray.float64(2, 3) { [[1, INF, INF], [2, 3, 4]] }
    z[0, 0] = UNDEF
    assert_equal [1, 0], z.min_index(axis: 1).to_a
    assert_equal [1, 3], z.min_addr(axis: 1).to_a
  end

  def test_extremum_position_skips_nan
    assert_equal 1, CArray.float64(2) { [NAN, INF] }.min_index
    assert_equal 1, CArray.float64(2) { [NAN, -INF] }.max_index
    assert_equal 1, CArray.float32(2) { [NAN, INF] }.min_index
    assert_same UNDEF, CArray.float64(2) { [NAN, NAN] }.min_index
    assert_equal 1, CArray.float64(3) { [2.0, 1.0, 1.0] }.min_index   # first of a tie
  end

  def test_object_wmean_zero_weight_sum_under_keep_axis
    o = CArray.object(3) { [1, 2, 3] }
    assert_same UNDEF, o.wmean(0)
    assert_equal [UNDEF], o.wmean(0, keep_axis: true).to_a
    assert_equal [2], o.wmean(2, keep_axis: true).to_a
  end
end

# Test for CArray#seq! / #seq per-axis fill (axis: kwarg).
# Without axis: the progression runs in row-major order over the whole
# array (legacy behavior); with axis: k it runs along axis k and repeats
# across the other axes.

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../ext", __dir__)
require "test/unit"
require "carray"

class TestSeqPerAxis < Test::Unit::TestCase

  # Brute-force reference: cell value = off + step * coord_along_axis.
  def ref_axis(shape, axis, off, step)
    a = CArray.float64(*shape)
    a.elements.times do |n|
      rem = n
      mi = shape.each_index.map do |i|
        stride = shape[(i + 1)..].inject(1, :*)
        q = rem / stride
        rem %= stride
        q
      end
      a[*mi] = off + step * mi[axis]
    end
    a
  end

  def test_flat_default_unchanged
    assert_equal([[0, 1, 2], [3, 4, 5]], CArray.int32(2, 3).seq!.to_a)
    assert_equal([[10, 12], [14, 16]], CArray.int32(2, 2).seq!(10, 2).to_a)
  end

  def test_numeric_per_axis_matches_reference
    [[3, 4], [2, 3, 4], [5], [4, 1, 3]].each do |shape|
      shape.each_index do |ax|
        got = CArray.float64(*shape).seq!(10.0, 2.0, axis: ax)
        assert_equal(ref_axis(shape, ax, 10.0, 2.0).to_a, got.to_a,
                     "shape=#{shape.inspect} axis=#{ax}")
      end
    end
  end

  def test_axis0_holds_constant_over_inner_block
    # axis 0 of (2,3): each outer row is a single seq value repeated.
    assert_equal([[100, 100, 100], [110, 110, 110]],
                 CArray.int32(2, 3).seq!(100, 10, axis: 0).to_a)
  end

  def test_innermost_axis_is_a_ramp
    assert_equal([[0, 1, 2, 3], [0, 1, 2, 3], [0, 1, 2, 3]],
                 CArray.int32(3, 4).seq!(0, 1, axis: 1).to_a)
  end

  def test_negative_axis_normalized
    a = CArray.int32(3, 4).seq!(0, 1, axis: -1)
    b = CArray.int32(3, 4).seq!(0, 1, axis: 1)
    assert_equal(b.to_a, a.to_a)
  end

  def test_float_step_per_axis
    assert_equal([[0.0, 0.5, 1.0], [0.0, 0.5, 1.0]],
                 CArray.float64(2, 3).seq!(0.0, 0.5, axis: 1).to_a)
  end

  def test_seq_non_destructive_per_axis
    src = CArray.int32(2, 3) { -1 }
    out = src.seq(100, 10, axis: 0)
    assert_equal([[100, 100, 100], [110, 110, 110]], out.to_a)
    assert_equal([[-1, -1, -1], [-1, -1, -1]], src.to_a, "source must be untouched")
  end

  def test_object_per_axis
    assert_equal([["a", "b", "c"], ["a", "b", "c"]],
                 CArray.object(2, 3).seq!("a", :succ, axis: 1).to_a)
    assert_equal([["a", "a", "a"], ["b", "b", "b"]],
                 CArray.object(2, 3).seq!("a", :succ, axis: 0).to_a)
  end

  def test_object_plus_progression_per_axis
    assert_equal([[0, 2, 4], [0, 2, 4]],
                 CArray.object(2, 3).seq!(0, 2, axis: 1).to_a)
  end

  def test_view_delivery_writes_through_parent
    a = CArray.int32(4, 4) { 0 }
    a[1..2, nil].seq!(0, 1, axis: 1)
    assert_equal([0, 1, 2, 3], a[1, nil].to_a)
    assert_equal([0, 1, 2, 3], a[2, nil].to_a)
    assert_equal([0, 0, 0, 0], a[0, nil].to_a)
    assert_equal([0, 0, 0, 0], a[3, nil].to_a)
  end

  def test_transposed_view_materialize_sync
    t = CArray.int32(3, 2) { 0 }
    t.transpose.seq!(0, 1, axis: 0)
    assert_equal([[0, 1], [0, 1], [0, 1]], t.to_a)
  end

  def test_multi_axis_rejected
    assert_raise(ArgumentError) { CArray.int32(2, 3).seq!(0, 1, axis: [0, 1]) }
  end

  def test_out_of_range_axis_rejected
    assert_raise(ArgumentError) { CArray.int32(2, 3).seq!(0, 1, axis: 5) }
    assert_raise(ArgumentError) { CArray.int32(2, 3).seq!(0, 1, axis: -3) }
  end

  def test_mask_cleared_per_axis
    # seq! clears all mask state (matching the flat fill); the previously
    # masked cell is overwritten with its progression value.
    a = CArray.int32(2, 3) { 0 }
    a[0, 0] = UNDEF
    a.seq!(0, 1, axis: 1)
    assert_equal(0, a.count_masked)
    assert_equal([[0, 1, 2], [0, 1, 2]], a.to_a)
  end
end

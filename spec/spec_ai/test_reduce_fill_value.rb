require "test/unit"
require "carray"

# A reduction's fill_value: is what a store into the result would make of
# it, with or without axis:, and fill_value: UNDEF leaves the result
# undefined.  Without axis: the result is a scalar, so it used to come back
# as given, unconverted.
class TestReduceFillValue < Test::Unit::TestCase

  def setup
    @f = CArray.float64(3, 4).seq.tap { |x| x[0, 0] = UNDEF; x[0, 1] = UNDEF }
    @i = CArray.int32(3, 4).seq.tap { |x| x[0, 0] = UNDEF; x[0, 1] = UNDEF }
    @u = CArray.uint8(4).seq.tap { |x| x[0] = UNDEF }
  end

  def test_whole_and_per_axis_agree
    assert_equal 9,    @i.min(min_count: 100, fill_value: 9.9)
    assert_equal 9,    @i.min(axis: 1, min_count: 3, fill_value: 9.9)[0]
    assert_equal 9.9,  @f.sum(min_count: 100, fill_value: 9.9)
    assert_equal 9.9,  @f.sum(axis: 1, min_count: 3, fill_value: 9.9)[0]
    assert_equal 241,  @u.accumulate(min_count: 100, fill_value: -9999)
  end

  def test_undef_fill_leaves_the_result_undefined
    assert_equal UNDEF, @f.sum(min_count: 100, fill_value: UNDEF)
    assert_equal UNDEF, @f.sum(axis: 1, min_count: 3, fill_value: UNDEF)[0]
    assert_equal UNDEF, @f.median(axis: 1, min_count: 3, fill_value: UNDEF)[0]
    assert_equal UNDEF, @f.percentile(50, min_count: 100, fill_value: UNDEF)
    assert_equal UNDEF, @f.windows(-1..1, -1..1).sum(min_count: 9, fill_value: UNDEF)[0, 0]
  end

  def test_minmax_fills_both_members
    lo, hi = @f.minmax(axis: 1, min_count: 3, fill_value: 9)
    assert_equal [9.0, 9.0], [lo[0], hi[0]]
    assert_equal [9.0, 9.0], @f.minmax(min_count: 100, fill_value: 9)
  end

  def test_median_takes_a_fill_as_a_store_would
    assert_equal 9.9, @f.median(min_count: 100, fill_value: 9.9)
    assert_equal 9.9, @f.median(axis: 1, min_count: 3, fill_value: 9.9)[0]
    # A fill a float array cannot hold is refused by both, as a store is.
    assert_raise(ArgumentError) { @f.sum(min_count: 100, fill_value: "x") }
    assert_raise(ArgumentError) { @f.median(min_count: 100, fill_value: "x") }
  end

end

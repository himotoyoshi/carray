$LOAD_PATH.unshift File.expand_path('../../ext', __dir__)
$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'carray'
require 'test/unit'

# Arguments of the binning and counting methods: a fill is written where it
# was asked for, a count is an Integer, and `axis: nil` means the default.

class TestBinFills < Test::Unit::TestCase

  # The under side is found before either fill is written, so lfill equal
  # to the over index is not taken for an over-range cell.
  def test_lfill_equal_to_the_bin_count
    v = CA_FLOAT64([-1, 0.5, 5])
    e = CA_FLOAT64([0, 1, 2, 3])
    assert_equal [3, 0, 7], v.bin_to(e, lfill: 3, ufill: 7).to_a
    assert_equal [0, 0, -1], v.bin_to(e, lfill: 0, ufill: -1).to_a
  end

  def test_bins_is_an_integer
    assert_raise(TypeError) { CA_FLOAT64([0.1]).bin(0, 1, bins: 2.5) }
  end

end

class TestHistogramAxisNil < Test::Unit::TestCase

  def test_nil_is_the_default_pair
    x = CArray.float64(5, 2).seq
    e = CArray.float64(3).seq(0, 5.0)
    assert_equal x.histogram(edges: [e, e]).counts.to_a,
                 x.histogram(edges: [e, e], axis: nil).counts.to_a
    l = CA_INT64([[0, 1], [1, 0]])
    assert_equal l.bincount_nd(lengths: [2, 2]).full_counts.to_a,
                 l.bincount_nd(lengths: [2, 2], axis: nil).full_counts.to_a
  end

  def test_histogram1d_nil_is_the_last_axis
    x = CArray.float64(10).seq
    e = CArray.float64(3).seq(0, 5.0)
    assert_equal x.histogram1d(edges: e).counts.to_a,
                 x.histogram1d(edges: e, axis: nil).counts.to_a
  end

  def test_a_single_axis_is_refused_with_its_name
    x = CArray.float64(5, 2).seq
    e = CArray.float64(3).seq(0, 5.0)
    assert_raise(ArgumentError) { x.histogram(edges: [e, e], axis: 1) }
  end

end

class TestBincountArguments < Test::Unit::TestCase

  def test_length_is_a_non_negative_integer
    l = CA_INT32([0, 1, 1])
    assert_raise(TypeError) { l.bincount(length: 6.7) }
    assert_raise(TypeError) { l.bincount(length: nil) }
    assert_raise(ArgumentError) { l.bincount(length: -3) }
    assert_raise(ArgumentError) { CA_INT32([]).bincount(length: -3) }
    assert_equal [1, 2, 0, 0], l.bincount(length: 4).to_a
  end

  def test_weights_of_another_kind_name_their_type
    l = CA_INT32([0, 1, 1])
    e = assert_raise(CArray::DataTypeError) { l.bincount(weights: CArray.boolean(3)) }
    assert_match(/boolean/, e.message)
    e = assert_raise(CArray::DataTypeError) { l.bincount(weights: CA_INT64([1, 2, 3]).timedelta(unit: :s)) }
    assert_match(/CATimedelta/, e.message)
  end

  def test_bincount_nd_lengths_are_integers
    assert_raise(TypeError) { CA_INT64([[0], [1]]).bincount_nd(lengths: [2.9]) }
  end

end

class TestRandomBounds < Test::Unit::TestCase

  def test_integer_bounds_must_fit_the_type
    assert_raise(RangeError) { CArray.int8(10).random!(0, 1000) }
    assert_raise(RangeError) { CArray.uint8(10).random!(-5, 5) }
  end

  def test_integer_array_takes_integer_bounds
    assert_raise(TypeError) { CArray.int32(10).random!(1.5) }
    assert_raise(TypeError) { CArray.int32(10).random!(0, 2.5) }
  end

  def test_the_whole_range_of_a_type
    a = CArray.int8(4000).random!(-128..127, rng: Random.new(1))
    assert_equal [-128, 127], [a.min, a.max]
    CArray.int64(3).random!(-2**63..2**63 - 1)
    u = CArray.uint64(1000).random!(2**64 - 10..2**64 - 1, rng: Random.new(2))
    assert u.min >= 2**64 - 10
    assert_equal 2**64 - 1, u.max
  end

  def test_float_bounds_are_finite
    assert_raise(ArgumentError) { CArray.float64(3).random!(Float::NAN, 1) }
    assert_raise(ArgumentError) { CArray.float64(3).random!(-Float::INFINITY, Float::INFINITY) }
  end

end

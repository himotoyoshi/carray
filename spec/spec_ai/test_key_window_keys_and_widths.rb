$LOAD_PATH.unshift File.expand_path('../../ext', __dir__)
$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'carray'
require 'test/unit'

# windows(on:) compares keys by their differences, so an integer key that
# does not fit int64 as a value still has windows, and a refused width or
# option is said rather than answered.

class TestKeyWindowIntegerKeys < Test::Unit::TestCase

  def sums (key, before)
    CA_FLOAT64([1, 2]).windows(on: key, before: before, exclude: nil).sum.to_a
  end

  def test_uint64_keys_above_int64_max
    assert_equal [1.0, 3.0], sums(CA_UINT64([2**63 - 1, 2**63]), 1)
    assert_equal [1.0, 2.0], sums(CA_UINT64([2**63 - 1, 2**63 + 1]), 1)
  end

  def test_narrow_signed_keys_at_their_extremes
    assert_equal [1.0, 3.0], sums(CA_INT8([-128, 127]), 255)
    assert_equal [1.0, 2.0], sums(CA_INT8([-128, 127]), 254)
  end

  def test_a_span_beyond_int64_is_refused
    assert_raise(ArgumentError) { sums(CA_UINT64([0, 2**64 - 1]), 1) }
  end

  # A width given as a Float does not make integer keys compare as float64:
  # above 2**53 two keys would round to one.
  def test_float_width_on_keys_above_2_53
    k = CA_INT64([2**53, 2**53 + 1])
    assert_equal [1.0, 2.0], sums(k, 0.0)
    assert_equal [1.0, 3.0], sums(k, 1.0)
    assert_equal [1.0, 2.0], sums(k, 0.5)
    assert_equal [1.0, 3.0], sums(k, Float::INFINITY)
  end

  # With interval:, a window that can hold no key is refused: there is no
  # grid point for is_complete to check.
  def test_an_empty_window_with_interval_is_refused
    k = CA_INT64([0, 1, 2])
    v = CA_FLOAT64([1, 2, 3])
    assert_raise(ArgumentError) { v.windows(on: k, before: 0, after: 0, exclude: :both, interval: 1) }
    assert_raise(ArgumentError) { v.windows(on: k, before: 0, exclude: :lower, interval: 1) }
    assert_equal [true] * 3, v.windows(on: k, before: 0, exclude: nil, interval: 1).is_complete.to_a
    assert_equal [0.0] * 3, v.windows(on: k, before: 0, after: 0, exclude: :both).sum.to_a
  end

  # A fractional width bounds an integer key at its floor, included, also
  # on the side exclude: names.
  def test_fractional_width_with_exclude
    k = CA_INT64([0, 1, 2])
    a = CA_FLOAT64([1, 2, 4])
    assert_equal [1.0, 3.0, 6.0], a.windows(on: k, before: 1.5, exclude: :lower).sum.to_a
    assert_equal [1.0, 2.0, 4.0], a.windows(on: k, before: 1.0, exclude: :lower).sum.to_a
  end

end

class TestKeyWindowTimeOnAFinerGrid < Test::Unit::TestCase

  # A width that needs a finer grid than the key's unit scales the ticks;
  # measured from the earliest key they fit int64 even near its end.
  def test_width_finer_than_the_unit_late_in_the_range
    d = CArray.time(%w[2262-04-11 2262-04-12], unit: :D)
    w = CATimedelta::Element.new(86400 * 10**9 + 1, :ns)
    got = CA_FLOAT64([1, 2]).windows(on: d, before: w, exclude: nil).sum.to_a
    assert_equal [1.0, 3.0], got
  end

end

class TestKeyWindowRefusals < Test::Unit::TestCase

  def test_nan_width_is_refused_like_nan_interval
    a = CA_FLOAT64([1, 2, 3])
    k = CA_FLOAT64([0, 1, 2])
    assert_raise(ArgumentError) { a.windows(on: k, before: Float::NAN) }
    assert_raise(ArgumentError) { a.windows(on: k, after: Float::NAN) }
    assert_raise(ArgumentError) { a.windows(on: k, before: 1, interval: Float::NAN) }
  end

  def test_offset_window_options_are_refused
    a = CA_FLOAT64([1, 2, 3])
    k = CA_FLOAT64([0, 1, 2])
    assert_raise(ArgumentError) { a.windows(on: k, before: 1, fill_value: 9) }
    assert_raise(ArgumentError) { a.windows(on: k, before: 1, bounds: :nearest) }
  end

  def test_offset_windows_keep_their_options
    a = CA_FLOAT64([1, 2, 3])
    assert_equal [4.0, 6.0, 8.0], a.windows(-1..1, bounds: :nearest).sum.to_a
  end

end

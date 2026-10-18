require "test/unit"
require "carray"

class TestRoundDigits < Test::Unit::TestCase
  FLOATS = [1.005, 2.675, 1.15, -1.005, 0.285, 1.255, 8.345, 12345.678,
            -12345.678, 25.0, -25.0, 5.9, 4.9, 1e-30, -1e-30,
            1.0000000000000002, 0.1, 2.0**60, 1e20, 123.456]

  def test_float_digits_match_float_round
    [-20, -3, -1, 1, 2, 3, 10, 14, 15, 16, 17, 300].each do |nd|
      assert_equal FLOATS.map { |x| x.round(nd).to_f },
                   CA_FLOAT64(FLOATS).round(nd).to_a, "ndigits #{nd}"
    end
  end

  def test_random_floats_match_float_round
    srand(7)
    xs = Array.new(20000) { (rand - 0.5) * 10.0**rand(-8..12) }
    [1, 2, 5, -2].each do |nd|
      assert_equal xs.map { |x| x.round(nd).to_f }, CA_FLOAT64(xs).round(nd).to_a
    end
  end

  def test_keeps_data_type_and_mask
    a = CA_FLOAT32([1.25, 2.5, 3.75])
    a[1] = UNDEF
    r = a.round(1)
    assert_equal :float32, r.data_type
    assert_equal [CA_FLOAT32([1.3])[0], UNDEF, CA_FLOAT32([3.8])[0]], r.to_a
  end

  def test_zero_digits_is_round_without_digits
    a = CA_FLOAT64([2.5, -2.5, 1.4])
    assert_equal a.round.to_a, a.round(0).to_a
  end

  def test_non_finite_values_pass_through
    a = CA_FLOAT64([Float::INFINITY, -Float::INFINITY])
    assert_equal a.to_a, a.round(-1).to_a
    assert_equal a.to_a, a.round(2).to_a
    assert_predicate a.round(2).is_nan.count(true), :zero?
    assert CA_FLOAT64([Float::NAN]).round(2)[0].nan?
  end

  def test_integers_round_as_integer_round
    v = [0, 5, 15, 25, -25, 125, -125, 99, 1049, -1050]
    [-1, -2, -3].each do |nd|
      assert_equal v.map { |x| x.round(nd) }, CA_INT64(v).round(nd).to_a
    end
    assert_equal v, CA_INT64(v).round(2).to_a
    assert_equal [20, 30, 250], CA_UINT8([24, 25, 249]).round(-1).to_a
  end

  def test_integer_result_that_does_not_fit_raises
    assert_raise(RangeError) { CA_INT8([125]).round(-1) }
    assert_raise(RangeError) { CA_UINT8([255]).round(-1) }
    assert_raise(RangeError) { CA_INT64([2**63 - 1]).round(-1) }
  end

  def test_objects_round_each_element
    assert_equal [1.01, Rational(33, 100), 7], CA_OBJECT([1.005, Rational(1, 3), 7]).round(2).to_a
  end

  def test_bang
    a = CA_FLOAT64([1.234, 5.678])
    assert_same a, a.round!(1)
    assert_equal [1.2, 5.7], a.to_a
  end

  def test_view_and_lazy
    a = CA_FLOAT64([[1.234, 2.345], [3.456, 4.567]])
    assert_equal [2.3, 4.6], a[nil, 1].round(1).to_a
    assert_equal [1.2, 2.3, 3.5, 4.6], a.lazy.round(1).to_a.flatten
  end

  def test_refusals
    assert_raise(TypeError) { CA_FLOAT64([1.5]).round(1.5) }
    assert_raise(CArray::DataTypeError) { CA_CMPLX128([1]).round(2) }
  end
end

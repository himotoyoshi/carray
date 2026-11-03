# frozen_string_literal: true

require "test/unit"
require "carray"

# CArray#== asks whether two arrays hold the same contents: a NaN equals a
# NaN at the same position (whatever its payload, in a float, a complex part
# or an object cell) and -0.0 equals 0.0. #eq stays the IEEE comparison of
# each cell, and #eql? stays bitwise.
class TestEqualNaN < Test::Unit::TestCase
  NAN = Float::NAN

  def test_a_nan_equals_a_nan
    x = CA_FLOAT64([1, NAN])
    assert_equal true, x == x
    assert_equal true, x == x.copy
    assert_equal true, x == CA_FLOAT64([1, -NAN])
    assert_equal true, CA_FLOAT32([NAN]) == CA_FLOAT32([NAN])
    assert_equal false, CA_FLOAT64([NAN]) == CA_FLOAT64([1])
  end

  def test_complex_parts
    assert_equal true,  CA_CMPLX128([Complex(NAN, 1)]) == CA_CMPLX128([Complex(NAN, 1)])
    assert_equal true,  CA_CMPLX64([Complex(1, NAN)]) == CA_CMPLX64([Complex(1, NAN)])
    assert_equal false, CA_CMPLX128([Complex(NAN, 1)]) == CA_CMPLX128([Complex(NAN, 2)])
  end

  def test_object_cells
    assert_equal true, CA_OBJECT([NAN, 1]) == CA_OBJECT([0.0 / 0.0, 1])
    assert_equal false, CA_OBJECT([NAN]) == CA_OBJECT([1.0])
  end

  def test_masked_cells_and_zero
    m = CA_FLOAT64([NAN, 2]); m[1] = UNDEF
    assert_equal true, m == m.copy
    assert_equal true, CA_FLOAT64([-0.0]) == CA_FLOAT64([0.0])
  end

  def test_eq_and_eql_are_unchanged
    x = CA_FLOAT64([1, NAN])
    assert_equal [true, false], x.eq(x).to_a
    assert_equal false, CA_FLOAT64([-0.0]).eql?(CA_FLOAT64([0.0]))
    assert_equal true, x.eql?(x.copy)
  end

  def test_a_frame_with_nan_equals_its_copy_and_its_csv
    df = CAFrame.new("f" => CA_FLOAT64([1, NAN]))
    assert_equal true, df == df.copy
    assert_equal true, CAFrame.from_csv(df.to_csv) == df
  end

  # An object cell equals itself first, as in Array#== and Array#eql?, so an
  # array holding a NaN object equals its copy and finds it as a Hash key.
  def test_object_cells_equal_themselves
    require "bigdecimal"
    [Float::NAN, Complex(Float::NAN, 0), BigDecimal("NaN")].each do |nan|
      x = CA_OBJECT([nan, 1])
      assert_true x == x.copy, nan.inspect
      assert_true x.eql?(x.copy), nan.inspect
      assert_equal :found, { x => :found }[x.copy], nan.inspect
    end
  end

  def test_distinct_objects_still_answer_for_themselves
    assert_true  CA_OBJECT([Float::NAN]) == CA_OBJECT([0.0 / 0.0])
    assert_false CA_OBJECT([Float::NAN]).eql?(CA_OBJECT([0.0 / 0.0]))
    assert_false CA_OBJECT([Object.new]) == CA_OBJECT([Object.new])
    assert_true  CA_OBJECT([1]) == CA_OBJECT([1.0])
    assert_false CA_OBJECT([1]).eql?(CA_OBJECT([1.0]))
  end
end

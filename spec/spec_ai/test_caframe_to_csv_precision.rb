# frozen_string_literal: true

require "test/unit"
require "carray"
require "stringio"

# to_csv(precision:) writes each float cell rounded to that many places.
class TestCAFrameToCsvPrecision < Test::Unit::TestCase
  def frame
    f = CA_FLOAT64([1.23456, Float::NAN, 2.0 / 3, Float::INFINITY])
    f[3] = UNDEF
    CAFrame.new("f" => f, "c" => CA_CMPLX128([Complex(1.234, 5.678), 0, 1, 2]),
                "i" => CA_INT32([1, 2, 3, 4]), "s" => CArray.string(%w[a b c d]))
  end

  def test_rounded
    csv = frame.to_csv(precision: 2)
    assert_equal ["f,c,i,s", "1.23,1.23+5.68i,1,a", "NaN,0.0+0.0i,2,b", "0.67,1.0+0.0i,3,c", ",2.0+0.0i,4,d"],
                 csv.lines.map(&:chomp)
  end

  def test_without_precision_a_float_goes_out_in_full
    assert_match(/\A0\.6666666666666666,/, frame.to_csv.lines[3])
  end

  def test_read_back
    back = CAFrame.from_csv(StringIO.new(frame.select("f").to_csv(precision: 3)))
    assert_equal [1.235, 0.667], [back["f"][0], back["f"][2]]
  end

  def test_zero_places_still_writes_floats
    df = CAFrame.new("x" => CA_FLOAT64([2.5, -0.4]), "z" => CA_CMPLX128([Complex(1.6, 2.4), 0]))
    assert_equal ["x,z", "3.0,2.0+2.0i", "0.0,0.0+0.0i"], df.to_csv(precision: 0).lines.map(&:chomp)
    assert_equal :float64, CAFrame.from_csv(StringIO.new(df.select("x").to_csv(precision: 0))).data_types["x"]
  end

  def test_refusals
    assert_raise(ArgumentError) { frame.to_csv(precision: -1) }
    assert_raise(ArgumentError) { frame.to_csv(precision: 1.5) }
  end
end

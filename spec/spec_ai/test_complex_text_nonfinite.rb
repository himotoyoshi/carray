# ----------------------------------------------------------------------------
#
#  spec_ai/test_complex_text_nonfinite.rb
#
#  Text read as a complex number takes what Complex#to_s writes for a part
#  that is not finite ("1.0+Infinity*i", "NaN+0.0i"), so a complex column
#  with one round-trips through to_csv / from_csv.
#
# ----------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "stringio"
require "test/unit"

class TestComplexTextNonfinite < Test::Unit::TestCase

  NAN = Float::NAN
  INF = Float::INFINITY

  VALUES = [
    Complex(1.5, -2.0), Complex(-0.0, NAN), Complex(1.0, INF), Complex(NAN, 0.0),
    Complex(-INF, -INF), Complex(2.0, -0.0), Complex(1.0e-300, 3.0e+300),
  ]

  def same (a, b)
    [[a.real, b.real], [a.imaginary, b.imaginary]].all? do |x, y|
      (x.nan? && y.nan?) || [x].pack("G") == [y].pack("G")
    end
  end

  def assert_same_values (got)
    assert_equal VALUES.size, got.size
    VALUES.zip(got).each { |v, g| assert(same(v, g), "#{v.inspect} read as #{g.inspect}") }
  end

  def test_object_text_to_cmplx128
    assert_same_values CA_OBJECT(VALUES.map(&:to_s)).to_type(:cmplx128).to_a
  end

  def test_csv_round_trip
    df = CAFrame.new("c" => CA_CMPLX128(VALUES))
    text = df.to_csv
    assert_same_values CAFrame.from_csv(StringIO.new(text), types: { "c" => :cmplx128 })["c"].to_a
    assert_same_values CAFrame.from_csv(StringIO.new(text))["c"].to_type(:cmplx128).to_a
  end

  def test_not_complex_text_stays_unreadable
    got = CA_OBJECT(["NaN+", "Infinity", "1+NaNi*i", "+NaN*i"]).to_type(:cmplx128)
    assert_equal [true, false, true, true], got.is_masked.to_a
  end

end

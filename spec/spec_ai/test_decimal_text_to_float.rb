require "test/unit"
require "carray"

# Text read as a float (to_type, a String stored into a float array, CAFrame
# #cast, from_csv with types:) is rounded correctly: the same double Ruby's
# Float() gives, to the last bit. The reader answers most text without
# strtod, so these sets aim at the places where that is easy to get wrong --
# an exact halfway point, the second half of the 128-bit power of five,
# subnormals, the ends of the range, and more than 19 digits.

class TestDecimalTextToFloat < Test::Unit::TestCase

  def assert_reads_as_float (strs)
    got = CA_OBJECT(strs).to_type(:float64).to_a
    want = strs.map { |t| Float(t) }
    bad = strs.each_index.reject { |i| [got[i]].pack("G") == [want[i]].pack("G") }
    assert bad.empty?, -> {
      i = bad[0]
      "#{bad.size} of #{strs.size} differ, e.g. #{strs[i]}: #{got[i].inspect}, not #{want[i].inspect}"
    }
  end

  def rng
    @rng ||= Random.new(20261009)
  end

  def random_doubles (n)
    Array.new(n) { rng.bytes(8).unpack1("G") }.select(&:finite?)
  end

  def test_17_to_19_digits_across_the_exponent_range
    assert_reads_as_float Array.new(100_000) { "#{rng.rand(10**(17 + rng.rand(3)))}e#{rng.rand(-350..320)}" }
  end

  def test_random_doubles_written_three_ways
    d = random_doubles(30_000)
    assert_reads_as_float d.map(&:to_s)
    assert_reads_as_float d.map { |x| format("%.17g", x) }
    assert_reads_as_float d.map { |x| format("%.25g", x) }      # more than 19 digits
  end

  def test_odd_integers_and_exact_halfway_points_past_2_to_the_53
    strs = []
    20_000.times do
      bits = 54 + rng.rand(10)
      w = rng.rand(1 << (bits - 1)) | (1 << (bits - 1)) | 1
      half = (w >> (bits - 53)) << (bits - 53) | (1 << (bits - 54))
      strs << w.to_s << half.to_s
      strs << "#{half}e#{rng.rand(1..23)}" if half.to_s.size <= 19
    end
    assert_reads_as_float strs
  end

  def test_subnormals
    d = Array.new(30_000) { [rng.rand(1 << 52)].pack("Q").unpack1("d") }
    assert_reads_as_float d.map(&:to_s)
    assert_reads_as_float d.map { |x| format("%.17g", x) }
  end

  def test_edges
    assert_reads_as_float %w[
      0 -0 0.0 -0.0 0e10 0.1 1e22 1e23 9007199254740992 9007199254740993
      18446744073709551615 123456789012345678e-10 0.000000000000000000000000000001
      2.2250738585072011e-308 2.2250738585072012e-308 2.2250738585072014e-308
      4.9406564584124654e-324 2.4703282292062327e-324 2.4703282292062328e-324
      1.7976931348623157e308 1.7976931348623158e308 1.7976931348623159e308
      1e309 1e-400 1e-342 1e-343 7.2057594037927933e16
    ]
  end

  def test_a_string_stored_into_a_float_array
    a = CArray.float64(2)
    a[0] = "1e23"
    a[1] = "2.2250738585072011e-308"
    assert_equal [[1e23].pack("G"), [Float("2.2250738585072011e-308")].pack("G")],
                 a.to_a.map { |x| [x].pack("G") }
  end

end

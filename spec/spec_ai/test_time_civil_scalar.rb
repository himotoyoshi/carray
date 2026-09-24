# The scalar civil-date kernel must answer exactly what the vectorized one
# answers.
#
# CATimeLiteral parses one literal at a time, and it used to reach the
# vectorized CATimeCivil.days_from_civil for each of them -- building three
# one-cell CArrays and paying a kernel call per literal.  In a bulk column
# parse that was where nearly all the time went (170k rows: 3.5 s, of which
# 3.1 s was this), so the single-date path now has its own Integer form.
#
# Two forms of one algebra drift unless something holds them together;
# these are that something.

require 'test/unit'
require 'carray'

class TestTimeCivilScalar < Test::Unit::TestCase

  def assert_same_as_vectorized (y, m, d)
    want = CATimeCivil.days_from_civil(CA_INT64([y]), CA_INT64([m]), CA_INT64([d]))[0]
    got  = CATimeCivil.days_from_civil_1(y, m, d)
    assert_equal want, got, "days_from_civil_1(#{y}, #{m}, #{d})"
  end

  def test_epoch_and_its_neighbours
    [[1970, 1, 1], [1969, 12, 31], [1970, 1, 2], [1970, 3, 1], [1969, 3, 1]].each do |ymd|
      assert_same_as_vectorized(*ymd)
    end
  end

  def test_march_boundary_both_sides
    # The algebra shifts the year at March, so the months around it are
    # where a transcription slip would show first.
    (1..12).each { |m| assert_same_as_vectorized(2019, m, 1) }
    (1..12).each { |m| assert_same_as_vectorized(-1, m, 28) }
  end

  def test_leap_days
    [[2000, 2, 29], [2024, 2, 29], [1900, 2, 28], [1600, 2, 29]].each do |ymd|
      assert_same_as_vectorized(*ymd)
    end
  end

  def test_era_boundaries_and_negative_years
    [[2000, 1, 1], [1600, 1, 1], [1200, 1, 1], [0, 1, 1], [-400, 1, 1],
     [-401, 12, 31], [-3000, 6, 15]].each do |ymd|
      assert_same_as_vectorized(*ymd)
    end
  end

  def test_random_dates
    srand 20260917
    2000.times do
      assert_same_as_vectorized(rand(-4000..4000), rand(1..12), rand(1..28))
    end
  end

  # The literal path is what the two forms serve; check it end to end.
  def test_parsed_literals_land_on_the_right_instant
    {
      "1970-01-01T00:00:00" => 0,
      "1969-12-31T23:59:59" => -1,
      "2000-02-29T12:00:00" => Time.utc(2000, 2, 29, 12).to_i,
      "2026-09-17T12:34:56" => Time.utc(2026, 9, 17, 12, 34, 56).to_i,
      "1583-01-01T00:00:00" => Time.utc(1583, 1, 1).to_i,
    }.each do |literal, ticks|
      assert_equal ticks, CArray.time([literal], unit: :s).ticks[0], literal
    end
  end

  def test_parsed_literals_with_an_explicit_format
    col = CArray.object(3) { |i| Kernel.format("%04d/01/02 03:04:05", 2000 + i) }
    t   = CArray.time(col, format: "%Y/%m/%d %H:%M:%S", unit: :s)
    assert_equal [Time.utc(2000, 1, 2, 3, 4, 5).to_i,
                  Time.utc(2001, 1, 2, 3, 4, 5).to_i,
                  Time.utc(2002, 1, 2, 3, 4, 5).to_i], t.ticks.to_a
  end

end

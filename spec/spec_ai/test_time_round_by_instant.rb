require "test/unit"
require "carray"

# round to a calendar bucket measures the distance by the instant: a :M or :Y
# tick is the start of its month or year, so it rounds as the same dates on
# :D do.
class TestTimeRoundByInstant < Test::Unit::TestCase

  def as_strings (t)
    t.to_a.map(&:to_s)
  end

  def test_month_to_year_matches_days
    months = %w[1889-07 1889-08 2024-07 2023-06 2023-07]
    m = CArray.time(months, unit: :M).round(unit: :Y)
    d = CArray.time(months.map { |s| s + "-01" }, unit: :D).round(unit: :Y)
    assert_equal %w[1889-01 1890-01 2024-01 2023-01 2023-01], as_strings(m)
    assert_equal as_strings(d).map { |s| s[0, 7] }, as_strings(m)
  end

  def test_month_to_quarter_matches_days
    months = %w[2024-01 2024-02 2024-03 2023-11]
    m = CArray.time(months, unit: :M).round(unit: "3 months")
    d = CArray.time(months.map { |s| s + "-01" }, unit: :D).round(unit: "3 months")
    assert_equal as_strings(d).map { |s| s[0, 7] }, as_strings(m)
  end

  def test_year_to_decade_matches_days
    years = %w[1884 1885 1886]
    y = CArray.time(years, unit: :Y).round(unit: "10 years")
    d = CArray.time(years.map { |s| s + "-01-01" }, unit: :D).round(unit: "10 years")
    assert_equal as_strings(d).map { |s| s[0, 4] }, as_strings(y)
  end

  def test_floor_and_ceil_unchanged
    m = CArray.time(%w[1889-07], unit: :M)
    assert_equal %w[1889-01], as_strings(m.floor(unit: :Y))
    assert_equal %w[1890-01], as_strings(m.ceil(unit: :Y))
  end

end

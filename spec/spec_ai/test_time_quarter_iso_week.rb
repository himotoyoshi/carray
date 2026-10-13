require "test/unit"
require "date"
require "carray"

# quarter, iso_week and iso_year, against Ruby's Date over two centuries.

class TestTimeQuarterIsoWeek < Test::Unit::TestCase

  def test_against_date
    d = CArray.time_range("1899-12-01", "2101-03-01", unit: :D)
    dates = d.to_a.map { |x| Date.parse(x.to_s) }
    week, year, quarter = d.iso_week.to_a, d.iso_year.to_a, d.quarter.to_a
    # the days that disagree, so a failure names them rather than printing
    # two centuries of weeks
    wrong = dates.each_with_index.filter_map do |x, i|
      got = [week[i], year[i], quarter[i]]
      want = [x.cweek, x.cwyear, (x.month - 1) / 3 + 1]
      "#{x}: #{got.inspect} != #{want.inspect}" unless got == want
    end
    assert_equal [], wrong.first(5)
  end

  # The days around New Year whose week is counted in the neighbouring year.
  def test_new_year
    t = CArray.time(%w[2021-01-03 2020-12-31 2026-12-31 2024-12-30 2027-01-01], unit: :D)
    assert_equal [53, 53, 53, 1, 53], t.iso_week.to_a
    assert_equal [2020, 2020, 2026, 2025, 2026], t.iso_year.to_a
  end

  def test_finer_and_coarser_grids
    s = CArray.time(%w[2021-01-03T23:00 2024-08-15T01:00], unit: :s)
    assert_equal [53, 33], s.iso_week.to_a
    assert_equal [1, 3], s.quarter.to_a
    assert_equal [1, 2, 4], CArray.time(%w[2024-01 2024-06 2024-12], unit: :M).quarter.to_a
  end

  def test_masked_cells
    t = CArray.time(%w[2024-02-10 2024-05-01], unit: :D)
    t[1] = UNDEF
    assert_equal [1, UNDEF], t.quarter.to_a
    assert_equal [6, UNDEF], t.iso_week.to_a
    assert_equal [2024, UNDEF], t.iso_year.to_a
  end
end

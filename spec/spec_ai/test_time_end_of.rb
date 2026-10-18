require "test/unit"
require "date"
require "carray"

# end_of(unit:, origin:) is the last tick of each element's bucket on the
# array's own grid, one tick before the next head floor would give; and
# days_in_month is the length of each element's month.

class TestTimeEndOf < Test::Unit::TestCase

  def days (*s) = CArray.time(s, unit: :D)
  def strs (t) = t.to_a.map { |x| x.equal?(UNDEF) ? x : x.to_s }

  def test_month_quarter_year
    d = days("2024-02-10", "2024-03-31", "2023-02-01", "1969-12-15")
    assert_equal %w[2024-02-29 2024-03-31 2023-02-28 1969-12-31], strs(d.end_of(unit: :M))
    assert_equal %w[2024-03-31 2024-03-31 2023-03-31 1969-12-31], strs(d.end_of(unit: "3 months"))
    assert_equal %w[2024-12-31 2024-12-31 2023-12-31 1969-12-31], strs(d.end_of(unit: :Y))
    # a fiscal year from April
    assert_equal %w[2024-03-31 2024-03-31 2023-03-31 1970-03-31],
                 strs(d.end_of(unit: "1 year", origin: "2000-04-01"))
    # an ISO week ends on Sunday
    assert_equal %w[2024-02-11 2024-03-31 2023-02-05 1969-12-21], strs(d.end_of(unit: :W))
    assert_equal strs(d), strs(d.end_of(unit: :D))
  end

  # Every day of a span against Date: the last day of its month.
  def test_against_date
    d = CArray.time_range("1899-12-01", "2101-03-01", unit: :D)
    want = d.to_a.map { |x| Date.parse(x.to_s) }.map { |x| Date.new(x.year, x.month, -1).to_s }
    got  = strs(d.end_of(unit: :M))
    wrong = want.each_index.filter_map { |i| "#{d[i]}: #{got[i]} != #{want[i]}" unless got[i] == want[i] }
    assert_equal [], wrong.first(5)
  end

  def test_finer_grids
    s = CArray.time(%w[2024-02-10T05:06:07 2024-12-31T23:59:59], unit: :s)
    assert_equal %w[2024-02-29T23:59:59Z 2024-12-31T23:59:59Z], strs(s.end_of(unit: :M))
    assert_equal %w[2024-02-10T05:59:59Z 2024-12-31T23:59:59Z], strs(s.end_of(unit: "1 hour"))
  end

  def test_month_grid
    m = CArray.time(%w[2024-02 2024-05], unit: :M)
    assert_equal %w[2024-03 2024-06], strs(m.end_of(unit: "3 months"))
    assert_equal %w[2024-12 2024-12], strs(m.end_of(unit: :Y))
  end

  # A bucket finer than the grid, or not a whole number of its ticks, has no
  # last tick on it.
  def test_refusals
    assert_raise(ArgumentError) { days("2024-02-10").end_of(unit: "6 hours") }
    assert_raise(ArgumentError) { CArray.time(%w[2024-01-01T00:10], unit: "10 minutes").end_of(unit: "15 minutes") }
    assert_raise(ArgumentError) { CArray.time(%w[2024-02], unit: :M).end_of(unit: :D) }
  end

  def test_month_end_series
    ends = CArray.time_range("2024-01-01", "2024-06-01", unit: :M).to_unit(:D).end_of(unit: :M)
    assert_equal %w[2024-01-31 2024-02-29 2024-03-31 2024-04-30 2024-05-31 2024-06-30], strs(ends)
  end

  def test_days_in_month
    d = days("2024-02-10", "2023-02-10", "2024-04-30", "1900-02-01", "2000-02-01")
    assert_equal [29, 28, 30, 28, 29], d.days_in_month.to_a
    assert_equal [false, false, true, false, false], d.day.eq(d.days_in_month).to_a
    assert_equal [29, 31], CArray.time(%w[2024-02 2024-05], unit: :M).days_in_month.to_a
    assert_equal [31], CArray.time(%w[2024], unit: :Y).days_in_month.to_a   # January's
  end

  def test_masked_cells
    d = days("2024-02-10", "2024-03-31")
    d[1] = UNDEF
    assert_equal ["2024-02-29", UNDEF], strs(d.end_of(unit: :M))
    assert_equal [29, UNDEF], d.days_in_month.to_a
  end
end

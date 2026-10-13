require "test/unit"
require "date"
require "carray"

# A month or year duration moves a time on a fixed grid as Ruby's Date#>>
# moves a date: the year and month move, the day stays unless the new month
# is shorter (then it is that month's last day), and the time of day stays.
# Only a grid that a day divides into whole ticks takes it, since on any other
# grid a month would leave the grid.

class TestTimeCalendarShift < Test::Unit::TestCase

  def months (n, unit = :M) = CATimedelta.wrap(CA_INT64([n].flatten), unit: unit)
  def days (*s) = CArray.time(s, unit: :D)

  def test_end_of_month
    t = days("2024-01-31", "2024-03-31", "2023-01-31", "2024-02-29")
    assert_equal %w[2024-02-29 2024-04-30 2023-02-28 2024-03-29], (t + months(1)).to_a.map(&:to_s)
    assert_equal %w[2023-12-31 2024-02-29 2022-12-31 2024-01-29], (t - months(1)).to_a.map(&:to_s)
    assert_equal %w[2025-01-31 2025-03-31 2024-01-31 2025-02-28], (t + months(1, :Y)).to_a.map(&:to_s)
    assert_equal %w[2024-07-31 2024-09-30 2023-07-31 2024-08-29], (t + months(2, "3 months")).to_a.map(&:to_s)
  end

  # Every cell answers as Date#>> does, before the epoch too, with the time
  # of day kept; a single value answers as the array does.
  def test_against_date
    rng = Random.new(11)
    500.times do
      date = Date.new(rng.rand(1600..2400), rng.rand(1..12), rng.rand(1..28)) + rng.rand(0..3)
      sec  = rng.rand(0...86400)
      n    = rng.rand(-40..40)
      t    = CArray.time([date.strftime("%Y-%m-%d")], unit: :s) + CATimedelta.wrap(CA_INT64([sec]), unit: :s)
      want = (date >> n).strftime("%Y-%m-%d") + "T" + Time.at(sec).utc.strftime("%H:%M:%S") + "Z"
      assert_equal want, (t + months(n))[0].to_s, "#{date} #{sec} #{n}"
      assert_equal want, (t[0] + CATimedelta::Element.new(n, :M)).to_s, "element #{date} #{sec} #{n}"
    end
  end

  def test_grids
    assert_equal ["2024-02-29T10:30:00Z"],
                 (CArray.time(["2024-01-31T10:30"], unit: "10 minutes") + months(1)).to_a.map(&:to_s)
    # a month moves a time off these grids
    assert_raise(ArgumentError) { CArray.time(["2024-01-31T07:00"], unit: "7 hours") + months(1) }
    assert_raise(ArgumentError) { CArray.time(["2024-01-29"], unit: :W) + months(1) }
    assert_raise(ArgumentError) { CArray.time(["2024-01-31"], unit: "3 days") + months(1) }
    # a month grid adds months as it did, and refuses a fixed duration as it did
    assert_equal ["2024-02"], (CArray.time(["2024-01"], unit: :M) + months(1)).to_a.map(&:to_s)
    assert_raise(ArgumentError) { CArray.time(["2024-01"], unit: :M) + CATimedelta.wrap(CA_INT64([1]), unit: :D) }
  end

  def test_operands
    t = days("2024-01-31", "2024-03-31")
    assert_equal %w[2024-02-29 2024-05-31], (t + months([1, 2])).to_a.map(&:to_s)
    assert_equal %w[2024-02-29 2024-04-30], (t + "1 month").to_a.map(&:to_s)
    assert_equal %w[2024-02-29 2024-04-30], (months(1) + t).to_a.map(&:to_s)
    t[1] = UNDEF
    assert_equal ["2024-02-29", UNDEF], (t + months(1)).to_a.map { |x| x.equal?(UNDEF) ? x : x.to_s }
  end

  # What a month is: these hold for Date#>> as well.
  def test_a_month_is_not_a_fixed_step
    jan31 = days("2024-01-31")
    assert_equal "2024-01-29", (jan31 + months(1) - months(1))[0].to_s             # not undone
    assert_equal "2024-03-29", (jan31 + months(1) + months(1))[0].to_s             # not
    assert_equal "2024-03-31", (jan31 + months(2))[0].to_s                         #   associative
    one_day = CATimedelta.wrap(CA_INT64([1]), unit: :D)
    jan30 = days("2024-01-30")
    assert_equal "2024-02-29", (jan30 + one_day + months(1))[0].to_s               # the order
    assert_equal "2024-03-01", (jan30 + months(1) + one_day)[0].to_s               #   matters
  end

  def test_out_of_range
    t = CArray.time(["2262-03-01"], unit: :ns)
    assert_raise(RangeError) { t + months(12) }
  end
end

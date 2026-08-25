# PROPOSAL_CAFACE_PHASE_2 F.4.x — CATime pandas-style field accessors

require 'test/unit'
require 'carray'

class TestCAFacePhase4 < Test::Unit::TestCase

  # ---- F.4.1: field accessors ----

  def test_year_month_day
    dt = CArray.time_series("2024-06-15", count: 3, unit: :D)
    assert_equal [2024, 2024, 2024], dt.year.to_a
    assert_equal [6, 6, 6], dt.month.to_a
    assert_equal [15, 16, 17], dt.day.to_a
  end

  def test_hour_minute_second
    # unit: :h で分以下は精度外 (= 12:30 → 12:00 に丸まる)
    dt = CArray.time_series("2024-06-15T12:30:00", count: 3, unit: :h)
    assert_equal [12, 13, 14], dt.hour.to_a
    assert_equal [0, 0, 0], dt.minute.to_a  # h 精度なので分丸まる
    # 分まで保持したい場合は unit: :m
    dt_m = CArray.time_series("2024-06-15T12:30:00", count: 3, unit: :m)
    assert_equal [12, 12, 12], dt_m.hour.to_a
    assert_equal [30, 31, 32], dt_m.minute.to_a
  end

  def test_weekday
    # 2024-06-15 is Saturday (6)
    dt = CArray.time_series("2024-06-15", count: 7, unit: :D)
    assert_equal [6, 0, 1, 2, 3, 4, 5], dt.weekday.to_a
  end

  def test_yday
    dt = CArray.time_series("2024-12-30", count: 3, unit: :D)
    assert_equal [365, 366, 1], dt.yday.to_a  # 2024 is leap, has 366 days
  end

  def test_is_leap
    require 'time'
    raw = CArray.int64(3)
    [Time.utc(2020,1,1).to_i, Time.utc(2021,1,1).to_i, Time.utc(2024,1,1).to_i].each_with_index {|v,i| raw[i] = v}
    dt = raw.time(unit: :s)
    leap = dt.is_leap.to_a
    assert_equal true,  leap[0]
    assert_equal false, leap[1]
    assert_equal true,  leap[2]
  end

  def test_field_accessor_face_stripped
    dt = CArray.time_series("2024-06-15", count: 3, unit: :D)
    # year は CArray (Integer)、Face stripped
    refute_kind_of CATime, dt.year
    assert_kind_of CArray, dt.year
  end

  # ---- F.4.2: strftime ----

  def test_strftime
    dt = CArray.time_series("2024-06-15", count: 3, unit: :D)
    r = dt.strftime("%Y-%m-%d")
    assert_instance_of CAString, r          # string array, not a bare object CArray
    assert_equal "2024-06-15", r[0]
    assert_equal "2024-06-16", r[1]
    # mask propagates
    dt.parent[1] = UNDEF
    assert_equal [false, true, false], dt.strftime("%Y-%m-%d").is_masked.to_a
  end

  def test_strftime_with_dayname
    dt = CArray.time_series("2024-06-17", count: 3, unit: :D)  # Monday
    days = dt.strftime("%A").to_a
    assert_equal "Monday", days[0]
    assert_equal "Tuesday", days[1]
  end

  # ---- F.4.x: array-level Time / DateTime conversion ----

  def test_to_time
    require 'time'
    dt = CArray.time_series("2024-06-15", count: 3, unit: :D)
    tt = dt.to_time
    assert_kind_of CArray, tt
    assert_equal :object, tt.data_type
    assert tt[0].is_a?(Time)
    assert_equal "2024-06-15T00:00:00Z", tt[0].iso8601
    assert_equal "2024-06-16T00:00:00Z", tt[1].iso8601
  end

  def test_to_time_subsecond
    require 'time'
    dt = CArray.int64(1) { 1500 }.time(unit: :ms)   # 1.5s past epoch
    assert_equal "1970-01-01T00:00:01.500Z", dt.to_time[0].iso8601(3)
  end

  def test_to_date
    require 'date'
    # sub-day unit floors to the day; calendar unit -> first of the month
    dt = CArray.time(%w[2024-06-15T12:30:45 2024-06-16T00:00:00], unit: :s)
    dd = dt.to_date
    assert_kind_of CArray, dd
    assert_equal :object, dd.data_type
    assert dd[0].is_a?(Date)
    assert_equal [Date.new(2024, 6, 15), Date.new(2024, 6, 16)], dd.to_a
    m = CArray.time_series("2024-03-15", count: 2, unit: :M)
    assert_equal [Date.new(2024, 3, 1), Date.new(2024, 4, 1)], m.to_date.to_a
    # mask propagates
    dt.parent[1] = UNDEF
    assert_equal [false, true], dt.to_date.is_masked.to_a
  end

  def test_to_datetime_no_half_day_offset
    # epoch must map to 1970-01-01T00:00, not the AJD-noon-offset 12:00
    require 'date'
    dt = CArray.int64(2) { |i| [0, 3661][i] }.time(unit: :s)   # epoch, +1h1m1s
    dd = dt.to_datetime
    assert dd[0].is_a?(DateTime)
    assert_equal "1970-01-01T00:00:00+00:00", dd[0].iso8601
    assert_equal "1970-01-01T01:01:01+00:00", dd[1].iso8601
  end

  # ---- F.4.3: parse_datetime ----

  def test_parse_datetime_iso
    strs = CArray.object(3) {|i| ["2024-01-15", "2024-02-15", "2024-03-15"][i]}
    dt = CArray.time(strs, unit: :D)
    assert_kind_of CATime, dt
    assert_equal :D, dt.unit.base
    assert_equal [1, 2, 3], dt.month.to_a
    assert_equal [15, 15, 15], dt.day.to_a
  end

  def test_parse_datetime_with_format
    strs = CArray.object(2) {|i| ["15/01/2024", "20/06/2024"][i]}
    dt = CArray.time(strs, format: "%d/%m/%Y", unit: :D)
    assert_equal [15, 20], dt.day.to_a
    assert_equal [1, 6], dt.month.to_a
  end

  def test_parse_datetime_missing_input_masks_output
    # A masked or nil cell must stay missing, not become a phantom epoch value.
    strs = CArray.object(4) { ["2024-01-01", "x", "2024-01-03", nil] }
    strs[1] = UNDEF
    dt = CArray.time(strs, unit: :D)
    assert_equal [false, true, false, true], dt.is_masked.to_a
    assert_equal 1, dt.day[0]
    assert_equal 3, dt.day[2]
  end

  def test_parse_datetime_unparseable_cell_masks_not_raises
    strs = CArray.object(3) { ["2024-01-01", "not-a-date", "2024-01-03"] }
    dt = CArray.time(strs, unit: :D, on_error: :mask)
    assert_equal [false, true, false], dt.is_masked.to_a
    # default is strict: an unparseable cell raises
    assert_raise(ArgumentError) { CArray.time(strs, unit: :D) }
  end

  # ---- date_range UTC fix (F.2.10 quirk 解消) ----

  def test_date_range_utc_no_timezone_drift
    dt = CArray.time_series("2024-01-15", count: 3, unit: :D)
    # 直接 dt[0] が 2024-01-15 (= UTC midnight) であることを確認
    assert_equal 2024, dt.year[0]
    assert_equal 1, dt.month[0]
    assert_equal 15, dt.day[0]
  end

  def test_datetime_utc_no_timezone_drift
    ts = CArray.time("2024-06-15", unit: :D)
    assert_equal [2024], ts.year.to_a
    assert_equal [6], ts.month.to_a
    assert_equal [15], ts.day.to_a
  end
end

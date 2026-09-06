# frozen_string_literal: true
#
# CATime / CATimedelta unit-change surface (#to_unit), the `step:` spacing of
# CArray.time_series, and the fixlen inspect path they exercise.
#
# to_unit changes the storage resolution: widening is exact, coarsening floors
# toward the past (a time is a point on an axis), and the calendar /
# fixed-length boundary is crossed by civil-date algebra rather than by a
# ratio.  CATimedelta#to_unit is the duration counterpart and truncates toward
# zero instead, because a duration is a magnitude.

require "test/unit"
require "carray"

class TestTimeUnitChange < Test::Unit::TestCase

  # -- inspect -------------------------------------------------------------

  def test_inspect_of_fixlen_face
    # the FIXLEN branch of the inspect type name formats inside an
    # instance_exec on the array, where a bare format() would resolve to the
    # public CArray#format rather than Kernel#format.
    dt = CArray.time(["2024-01-01"], unit: :D)
    assert_equal CA_FIXLEN, dt.data_type
    assert_match(/CATime\.fixlen\[8\]\(1\)/, dt.inspect)
    assert_match(/fixlen\[3\]\(2\)/, CArray.fixlen(2, bytes: 3).inspect)
  end

  # -- CATime#to_unit ------------------------------------------------------

  def test_to_unit_widens_to_finer_grid
    dt = CArray.time(["2024-01-01", "2024-01-02"], unit: :D)
    h  = dt.to_unit(:h)
    assert_equal CATime::Resolution.new(1, :h), h.unit
    assert_equal dt.ticks.to_a.map { |k| k * 24 }, h.ticks.to_a
    assert_equal dt.to_time.to_a, h.to_time.to_a       # no instant moves
  end

  def test_to_unit_folds_the_resolution_count
    dt = CArray.time(["2024-01-01 01:00"], unit: "1 hour")
    m10 = dt.to_unit("10 minutes")                     # 1 h = 6 ten-minute ticks
    assert_equal CATime::Resolution.new(10, :m), m10.unit
    assert_equal dt.ticks.to_a.map { |k| k * 6 }, m10.ticks.to_a
    assert_equal dt.to_time.to_a, m10.to_time.to_a
  end

  def test_to_unit_year_to_month
    y = CArray.time(["2024-01-01"], unit: :Y)
    assert_equal [(2024 - 1970) * 12], y.to_unit(:M).ticks.to_a
  end

  def test_to_unit_same_unit_is_a_noop
    dt = CArray.time(["2024-01-01"], unit: :D)
    assert_equal dt.ticks.to_a, dt.to_unit(:D).ticks.to_a
    assert_equal dt.unit, dt.to_unit("1 day").unit
  end

  def test_to_unit_propagates_the_mask
    dt = CArray.time(CA_OBJECT(["2024-01-01", nil]), unit: :D)
    h  = dt.to_unit(:h)
    assert_equal 1, h.count_masked
    assert_equal [19723 * 24, UNDEF], h.ticks.to_a
  end

  def test_to_unit_floors_a_coarser_target
    dt = CArray.time(["2024-01-01 05:00"], unit: :h)
    assert_equal ["2024-01-01"], dt.to_unit(:D).strftime("%Y-%m-%d").to_a
    assert_equal CATime::Resolution.new(1, :D), dt.to_unit(:D).unit
  end

  def test_to_unit_floors_toward_the_past_before_the_epoch
    # truncating toward zero would move a pre-epoch instant into the future;
    # the direction has to match CArray.time and #floor, which floor.
    dt = CArray.time(["1969-03-05 12:00"], unit: :h)
    assert_equal ["1969-03-05"], dt.to_unit(:D).strftime("%Y-%m-%d").to_a
    assert_equal ["1969-03"], CArray.time(["1969-03-05"], unit: :D).to_unit(:M).to_a.map(&:to_s)
    assert_equal ["1969-04"], CArray.time(["1969-05-20"], unit: :s).to_unit("3 months").to_a.map(&:to_s)
  end

  def test_to_unit_handles_a_partial_multiple
    # a "90 minutes" tick is 1.5 h: neither side is a whole multiple of the
    # other, so the ratio numerator has to survive the conversion.
    dt = CArray.time(["2024-01-01"], unit: "90 minutes")
    assert_equal ["2024-01-01 00:00"], dt.to_unit(:h).strftime("%Y-%m-%d %H:%M").to_a
    back = CArray.time(["2024-01-01 04:00"], unit: :h).to_unit("90 minutes")
    assert_equal ["2024-01-01 03:00"], back.strftime("%Y-%m-%d %H:%M").to_a
  end

  def test_to_unit_crosses_the_calendar_boundary
    # a :M value is a real instant (the month's first midnight), so it widens
    # exactly; the way back floors to the containing month.
    m = CArray.time(["2024-03-01"], unit: :M)
    assert_equal ["2024-03-01"], m.to_unit(:D).strftime("%Y-%m-%d").to_a
    assert_equal ["2024-03-01T00:00:00Z"],
                 m.to_unit(:s).strftime("%Y-%m-%dT%H:%M:%SZ").to_a
    assert_equal ["2024-03"], m.to_unit(:D).to_unit(:M).to_a.map(&:to_s)
    assert_equal ["2024-03"], CArray.time(["2024-03-05"], unit: :D).to_unit(:M).to_a.map(&:to_s)
  end

  def test_to_unit_refuses_a_week_target_across_the_boundary
    # a month head is not week-aligned, so widening would move the instant.
    assert_raise(ArgumentError) { CArray.time(["2024-03-01"], unit: :M).to_unit(:W) }
  end

  def test_to_unit_reaches_the_day_grid_of_a_calendar_series
    # the plotmill case: walk a quarterly grid on :M, then move the storage to
    # :D so a day-level offset can be added.
    m   = CArray.time_range("2019-09-01", "2020-06-01", unit: :M, step: "3 months")
    mid = m.to_unit(:D) + CATimedelta.wrap(CA_INT64([14]), unit: :D)
    assert_equal ["2019-09-15", "2019-12-15", "2020-03-15", "2020-06-15"],
                 mid.strftime("%Y-%m-%d").to_a
  end

  def test_to_unit_overflow_is_loud
    assert_raise(RangeError) { CA_INT64([10**15]).time(unit: :D).to_unit(:ns) }
  end

  def test_to_unit_overflow_ignores_a_masked_extreme
    # A masked cell carries no time, so the bits under the mask must not
    # decide whether the range fits: the same array raises unmasked.
    dt = CA_INT64([0, 10**15]).time(unit: :D)
    assert_raise(RangeError) { dt.to_unit(:ns) }
    dt.ticks.mask = CA_BOOLEAN([false, true])
    assert_equal [0, UNDEF], dt.to_unit(:ns).ticks.to_a
  end

  def test_to_unit_of_an_all_masked_or_empty_array
    all_masked = CA_INT64([5]).time(unit: :D)
    all_masked.ticks.mask = CA_BOOLEAN([true])
    assert_equal [UNDEF], all_masked.to_unit(:h).ticks.to_a
    assert_equal [], CArray.int64(0).time(unit: :D).to_unit(:h).ticks.to_a
  end

  # -- CATimedelta#to_unit -------------------------------------------------

  def test_timedelta_to_unit
    td = CArray.time(["2024-01-03"], unit: :D) - CArray.time(["2024-01-01"], unit: :D)
    assert_equal [2], td.ticks.to_a
    assert_equal [48], td.to_unit(:h).ticks.to_a
    assert_equal CATime::Resolution.new(1, :h), td.to_unit(:h).unit
  end

  def test_timedelta_to_unit_truncates_toward_zero
    # a duration is a magnitude, so it shrinks toward zero -- unlike a time,
    # which floors toward the past.
    td = CATimedelta.wrap(CA_INT64([30, -30]), unit: :h)
    assert_equal [1, -1], td.to_unit(:D).ticks.to_a
  end

  def test_timedelta_to_unit_keeps_the_ratio_numerator
    td = CATimedelta.wrap(CA_INT64([2, 3]), unit: "90 minutes")   # 3 h, 4.5 h
    assert_equal [3, 4], td.to_unit(:h).ticks.to_a
  end

  def test_timedelta_to_unit_refuses_to_cross_the_calendar_boundary
    # unlike an instant, a one-month duration has no length in days.
    td = CATimedelta.wrap(CA_INT64([1]), unit: :M)
    assert_raise(ArgumentError) { td.to_unit(:D) }
  end

  # -- CArray.time_series(step:) -------------------------------------------

  def test_time_series_step_coarser_than_unit
    ts = CArray.time_series("2024-01-01", count: 3, unit: :h, step: "1 day")
    assert_equal CATime::Resolution.new(1, :h), ts.unit
    assert_equal %w[2024-01-01 2024-01-02 2024-01-03],
                 ts.to_time.to_a.map { |t| t.strftime("%F") }
  end

  def test_time_series_step_defaults_to_one_unit_tick
    plain = CArray.time_series("2024-01-01", count: 3, unit: :h)
    assert_equal plain.ticks.to_a,
                 CArray.time_series("2024-01-01", count: 3, unit: :h, step: :h).ticks.to_a
    assert_equal [0, 1, 2], plain.ticks.to_a.map { |k| k - plain.ticks[0] }
  end

  def test_time_series_step_on_calendar_grid
    ts = CArray.time_series("2024-01-01", count: 3, unit: :M, step: "1 year")
    assert_equal [0, 12, 24], ts.ticks.to_a.map { |k| k - ts.ticks[0] }
  end

  def test_time_series_rejects_a_step_finer_than_the_unit
    assert_raise(ArgumentError) do
      CArray.time_series("2024-01-01", count: 3, unit: :D, step: "1 hour")
    end
  end

  def test_time_series_rejects_a_calendar_step_on_a_fixed_grid
    # a month is not a fixed number of hours
    assert_raise(ArgumentError) do
      CArray.time_series("2024-01-01", count: 3, unit: :h, step: "1 month")
    end
  end

  # -- CArray.time_range(step:) --------------------------------------------

  def test_time_range_step_coarser_than_unit
    tr = CArray.time_range("2024-06-15", "2024-06-18", unit: :h, step: "1 day")
    assert_equal CATime::Resolution.new(1, :h), tr.unit
    assert_equal %w[2024-06-15 2024-06-16 2024-06-17 2024-06-18],
                 tr.to_time.to_a.map { |t| t.strftime("%F") }
  end

  def test_time_range_step_defaults_to_one_unit_tick
    assert_equal CArray.time_range("2024-06-15", "2024-06-15 04:00", unit: :h).ticks.to_a,
                 CArray.time_range("2024-06-15", "2024-06-15 04:00",
                                   unit: :h, step: :h).ticks.to_a
  end

  def test_time_range_last_is_a_bound_not_a_member
    # the series stops at the last step at or before `last`
    tr = CArray.time_range("2024-06-15", "2024-06-18 13:00", unit: :h, step: "1 day")
    assert_equal %w[2024-06-15 2024-06-16 2024-06-17 2024-06-18],
                 tr.to_time.to_a.map { |t| t.strftime("%F") }
  end

  def test_time_range_step_phase_is_anchored_at_start
    tr = CArray.time_range("2024-06-15 09:00", "2024-06-17", unit: :h, step: "1 day")
    assert_equal ["2024-06-15 09:00", "2024-06-16 09:00"],
                 tr.to_time.to_a.map { |t| t.strftime("%F %H:%M") }
  end

  def test_time_range_step_degenerate_spans
    assert_equal 0, CArray.time_range("2024-06-18", "2024-06-15",
                                      unit: :h, step: "1 day").elements
    assert_equal 1, CArray.time_range("2024-06-15", "2024-06-15",
                                      unit: :h, step: "1 day").elements
  end

  def test_time_range_step_on_calendar_grid
    tr = CArray.time_range("2024-01-01", "2027-01-01", unit: :M, step: "1 year")
    assert_equal [0, 12, 24, 36], tr.ticks.to_a.map { |k| k - tr.ticks[0] }
  end

  def test_time_range_rejects_a_step_finer_than_the_unit
    assert_raise(ArgumentError) do
      CArray.time_range("2024-01-01", "2024-02-01", unit: :D, step: "1 hour")
    end
  end

  def test_time_range_rejects_a_calendar_step_on_a_fixed_grid
    assert_raise(ArgumentError) do
      CArray.time_range("2024-01-01", "2024-06-01", unit: :h, step: "1 month")
    end
  end

  # -- a time element as a start / origin literal --------------------------

  def test_a_time_element_is_a_start_literal
    # A ceil / floor answer feeds straight back in; going out through
    # DateTime to get there used to be the only way, and gives the same
    # series.
    start = CArray.time("2020-05-17T13:45:00Z", unit: :s)
                  .ceil(unit: "3 months", origin: "2000-01-01")[0]
    tr = CArray.time_range(start, "2021-02-01", unit: :M, step: "3 months")
    assert_equal %w[2020-07 2020-10 2021-01], tr.strftime("%Y-%m").to_a
    assert_equal CArray.time_range(start.to_datetime, "2021-02-01",
                                   unit: :M, step: "3 months").ticks.to_a,
                 tr.ticks.to_a
    assert_equal %w[2020-07 2020-10 2021-01],
                 CArray.time_series(start, count: 3, unit: :M,
                                    step: "3 months").strftime("%Y-%m").to_a
    assert_equal ["2020-07-01"], CArray.time(start, unit: :D).strftime("%F").to_a
  end

  def test_a_time_element_start_is_exact_for_every_unit
    # fixed unit: seconds read straight off the tick
    e = CArray.time("2024-06-15T07:30:00Z", unit: :s)[0]
    assert_equal ["2024-06-15T07:00:00Z", "2024-06-15T08:00:00Z"],
                 CArray.time_series(e, count: 2, unit: :h).strftime("%FT%TZ").to_a
    # calendar unit: the granule's first midnight, pre-epoch included
    pe = CArray.time("1965-03-01", unit: :M)[0]
    assert_equal %w[1965-03 1965-04 1965-05],
                 CArray.time_range(pe, "1965-05-01", unit: :M).strftime("%Y-%m").to_a
    assert_equal ["1965-03-01"], CArray.time(pe, unit: :D).strftime("%F").to_a
    # :Y element resolves to January
    y = CArray.time("2024-07-09", unit: :Y)[0]
    assert_equal ["2024-01-01"], CArray.time(y, unit: :D).strftime("%F").to_a
  end

  def test_a_time_element_is_an_origin
    start = CArray.time("2000-01-01", unit: :D)[0]
    dt    = CArray.time(["2020-08-15"], unit: :D)
    assert_equal dt.timesteps(unit: "1 month", origin: "2000-01-01").to_a,
                 dt.timesteps(unit: "1 month", origin: start).to_a
    # the month-head discipline still holds for an element origin
    mid = CArray.time("2000-01-15", unit: :D)[0]
    assert_raise(ArgumentError) { dt.timesteps(unit: "1 month", origin: mid) }
  end

end

# frozen_string_literal: true
#
# CATime / CATimedelta unit-change surface (#to_unit), the `step:` spacing of
# CArray.time_series, and the fixlen inspect path they exercise.
#
# to_unit re-expresses values on a finer grid and is deliberately strict: it
# decides on the units alone (source tick a whole multiple of the target
# tick), so it never rounds and never depends on the values.  Coarsening is
# floor / ceil / round, which say so at the call site.

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

  def test_to_unit_rejects_a_coarser_target
    dt = CArray.time(["2024-01-01 05:00"], unit: :h)
    assert_raise(ArgumentError) { dt.to_unit(:D) }
  end

  def test_to_unit_rejects_a_partial_multiple
    dt = CArray.time(["2024-01-01"], unit: "90 minutes")
    assert_raise(ArgumentError) { dt.to_unit(:h) }
  end

  def test_to_unit_rejects_crossing_the_calendar_boundary
    assert_raise(ArgumentError) { CArray.time(["2024-01-01"], unit: :D).to_unit(:M) }
    assert_raise(ArgumentError) { CArray.time(["2024-01-01"], unit: :M).to_unit(:D) }
  end

  def test_to_unit_overflow_is_loud
    assert_raise(RangeError) { CA_INT64([10**15]).time(unit: :D).to_unit(:ns) }
  end

  # -- CATimedelta#to_unit -------------------------------------------------

  def test_timedelta_to_unit
    td = CArray.time(["2024-01-03"], unit: :D) - CArray.time(["2024-01-01"], unit: :D)
    assert_equal [2], td.ticks.to_a
    assert_equal [48], td.to_unit(:h).ticks.to_a
    assert_equal CATime::Resolution.new(1, :h), td.to_unit(:h).unit
  end

  def test_timedelta_to_unit_rejects_a_coarser_target
    td = CArray.time(["2024-01-03"], unit: :h) - CArray.time(["2024-01-01"], unit: :h)
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

end

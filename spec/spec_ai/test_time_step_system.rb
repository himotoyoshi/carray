# frozen_string_literal: true
#
# CATime timestep system (N×base tick) — 2026-07-10.
#
# timesteps projects a time onto the integer index of its `unit`-wide
# bucket counted from origin (floor toward the past); floor/ceil/round build
# on it; from_timesteps inverts it; is_righttime flags on-grid cells.  All
# storage int64, vectorized, mask-propagating.  Integer path = fixed bucket on
# fixed storage + Y/M bucket on Y/M storage; the civil path (Y/M bucket on
# sub-day storage) uses civil-date algebra.
#
# See devel/PROPOSAL_CADATETIME_REBUILD.md.

require "test/unit"
require "carray"

class TestDatetimeStepSystem < Test::Unit::TestCase

  # -- Resolution parse ----------------------------------------------------

  def test_resolution_parse_string_and_symbol
    s = CATime::Resolution
    assert_equal [3, :h], [s.parse("3 hours").count, s.parse("3 hours").base]
    assert_equal [1, :M], [s.parse("1 month").count, s.parse("1 month").base]
    assert_equal [1, :h], [s.parse(:h).count, s.parse(:h).base]
    # singular / plural both accepted, count-1 bare word
    assert_equal s.parse("1 day"), s.parse("day")
    # tick_ratio folds count (seconds for fixed, months for calendar)
    assert_equal 600r, s.parse("10 minutes").tick_ratio
    assert_equal 3r,   s.parse("3 months").tick_ratio
  end

  def test_resolution_value_object_semantics
    a = CATime::Resolution.parse("3 hours")
    b = CATime::Resolution.parse(:h)
    assert_equal a, CATime::Resolution.new(3, :h)
    assert_not_equal a, b
    assert a.frozen?
    assert_equal({ a => 1 }[CATime::Resolution.new(3, :h)], 1)  # hashable key
  end

  def test_resolution_parse_rejects_compact_and_unknown
    assert_raise(ArgumentError) { CATime::Resolution.parse("3h") }      # no space
    assert_raise(ArgumentError) { CATime::Resolution.parse("2 fortnights") }
    assert_raise(ArgumentError) { CATime::Resolution.parse(:x) }
    assert_raise(ArgumentError) { CATime::Resolution.parse(3) }
  end

  # -- N×base storage tick -------------------------------------------------

  def test_nxbase_storage_holds_bucket_index
    d10 = CArray.time_series("2024-01-01T00:00:00Z", count: 4, unit: "10 minutes")
    assert_equal CATime::Resolution.new(10, :m), d10.unit
    # values are 10-minute indices since the epoch; to_time steps by 10 min
    assert_equal ["2024-01-01T00:00:00Z", "2024-01-01T00:10:00Z",
                  "2024-01-01T00:20:00Z", "2024-01-01T00:30:00Z"],
                 d10.to_time.to_a.map { |t| t.iso8601 }
    assert_equal [0, 1, 2, 3], (d10.parent - d10.parent[0]).to_a
  end

  def test_timesteps_no_unit_is_native_tick_index
    # timesteps with no unit buckets on the storage resolution itself, so it
    # returns a copy of the raw tick indices (== ticks's values).
    dt = CArray.time_series("2024-06-15T10:00", count: 3, unit: "10 minutes")
    assert_equal dt.ticks.to_a, dt.timesteps.to_a
    refute dt.timesteps.equal?(dt.parent)          # a fresh array, not the live storage
    assert dt.ticks.equal?(dt.parent)   # ticks stays zero-copy
  end

  # -- timesteps (fixed) ---------------------------------------------------

  def test_timesteps_hourly
    dt = CArray.time_series("2024-01-01T00:00:00Z", count: 6, unit: :h)
    t0 = "2024-01-01T00:00:00Z"
    assert_equal [0, 1, 2, 3, 4, 5], dt.timesteps(unit: "1 hour", origin: t0).to_a
    assert_equal [0, 0, 0, 1, 1, 1], dt.timesteps(unit: "3 hours", origin: t0).to_a
  end

  def test_timesteps_negative_pre_origin
    dt = CA_INT64([-2, -1, 0, 1, 2]).time(unit: :D)
    assert_equal [-2, -1, 0, 1, 2], dt.timesteps(unit: :D).to_a
    # floor toward the past, not toward zero
    assert_equal [-1, -1, 0, 0, 0], dt.timesteps(unit: "3 days").to_a
  end

  def test_timesteps_month_storage_is_pure_integer
    # :M value = months since 1970-01; 648 = 2024-01, 660 = 2025-01
    mo = CA_INT64([648, 649, 650, 660]).time(unit: :M)
    assert_equal [54, 54, 54, 55], mo.timesteps(unit: "1 year").to_a
  end

  def test_timesteps_fiscal_year_anchor_via_origin
    mo = CA_INT64([648, 660]).time(unit: :M)  # 2024-01, 2025-01
    # fiscal year starting each June: Jan 2024 falls in FY starting Jun 2023
    assert_equal [-1, 0], mo.timesteps(unit: "1 year", origin: "2024-06-01").to_a
  end

  # -- floor / ceil / round ------------------------------------------------

  def test_floor_ceil_round_bucket_heads
    dt = CArray.time_series("2024-01-01T00:00:00Z", count: 6, unit: :h)
    t0 = "2024-01-01T00:00:00Z"
    base = dt.parent[0]
    assert_equal [base, base, base, base + 3, base + 3, base + 3],
                 dt.floor(unit: "3 hours", origin: t0).parent.to_a
    assert_equal [base, base + 3, base + 3, base + 3, base + 6, base + 6],
                 dt.ceil(unit: "3 hours", origin: t0).parent.to_a
    # nearest, ties toward the future
    assert_equal [base, base, base + 3, base + 3, base + 3, base + 6],
                 dt.round(unit: "3 hours", origin: t0).parent.to_a
  end

  def test_round_exact_for_odd_step_ticks
    # step 3 (odd): midpoint at 1.5 rounds up
    dt = CA_INT64([0, 1, 2, 3, 4, 5]).time(unit: :h)
    assert_equal [0, 0, 3, 3, 3, 6], dt.round(unit: "3 hours").parent.to_a
  end

  def test_floor_result_is_face_same_unit
    dt = CArray.time_series("2024-01-01", count: 3, unit: :h)
    r = dt.floor(unit: "1 hour", origin: "2024-01-01T00:00:00Z")
    assert_instance_of CATime, r
    assert_equal :h, r.unit.base
  end

  # -- is_righttime --------------------------------------------------------

  def test_is_righttime_flags_grid_cells
    dt = CArray.time_series("2024-01-01T00:00:00Z", count: 6, unit: :h)
    t0 = "2024-01-01T00:00:00Z"
    assert_equal [true, false, false, true, false, false], dt.is_righttime(unit: "3 hours", origin: t0).to_a
  end

  # -- from_timesteps (inverse) --------------------------------------------

  def test_from_timesteps_round_trips_floor_by_instant
    dt = CArray.time_series("2024-01-01T00:00:00Z", count: 6, unit: :h)
    t0 = "2024-01-01T00:00:00Z"
    k  = dt.timesteps(unit: "3 hours", origin: t0)
    back = CATime.from_timesteps(k, unit: "3 hours", origin: t0)
    assert_equal dt.floor(unit: "3 hours", origin: t0).to_time.to_a,
                 back.to_time.to_a
  end

  def test_from_timesteps_scalar
    t0 = "2024-01-01T00:00:00Z"
    s = CATime.from_timesteps(2, unit: "3 hours", origin: t0)
    assert_instance_of CATime::Element, s
    assert_equal Time.utc(2024, 1, 1, 6, 0, 0), s.to_time  # 2 * 3h past origin
  end

  # -- week Monday default -------------------------------------------------

  def test_week_step_defaults_to_iso_monday
    # 2024-01-01 is a Monday; three cells: Mon, Thu, next Mon
    mon = CArray.time("2024-01-01T00:00:00Z", unit: :h).parent[0]
    wk  = CA_INT64([mon, mon + 24 * 3, mon + 24 * 7]).time(unit: :h)
    heads = wk.floor(unit: "1 week").to_time.to_a
    assert_equal ["Mon", "Mon", "Mon"], heads.map { |t| t.strftime("%a") }
    assert_equal ["2024-01-01", "2024-01-01", "2024-01-08"],
                 heads.map { |t| t.strftime("%F") }
  end

  def test_from_timesteps_answers_a_week_bucket_on_the_day_grid
    # A week grid counts from the epoch Thursday, so it cannot hold its own
    # bucket head (the ISO Monday, four days off every tick).  The answer
    # lands on :D, where the head is exact and the round trip closes.
    dt = CArray.time(%w[2024-06-10 2024-06-15 2024-06-17], unit: :D)  # Mon, Sat, Mon
    back = CATime.from_timesteps(dt.timesteps(unit: :W), unit: :W)
    assert_equal CATime::Resolution.new(1, :D), back.unit
    assert_equal dt.floor(unit: :W).ticks.to_a, back.ticks.to_a
    assert_equal %w[2024-06-10 2024-06-17],
                 back.strftime("%F").to_a.uniq

    head = CATime.from_timesteps(0, unit: :W)
    assert_instance_of CATime::Element, head
    assert_equal "1970-01-05", head.to_s                  # ISO Monday, not the epoch
    assert_equal CATime::Resolution.new(1, :D), head.unit
  end

  def test_from_timesteps_week_bucket_accepts_a_day_aligned_origin
    # The day grid can hold any midnight, so an explicit week origin is
    # reachable now; on the week grid it could not be expressed at all.
    assert_equal "2024-01-01", CATime.from_timesteps(0, unit: :W,
                                                     origin: "2024-01-01").to_s
    assert_equal "2024-01-15", CATime.from_timesteps(2, unit: :W,
                                                     origin: "2024-01-01").to_s
  end

  def test_from_timesteps_keeps_the_bucket_grid_for_other_units
    { :M => CATime::Resolution.new(1, :M),
      :D => CATime::Resolution.new(1, :D),
      :h => CATime::Resolution.new(1, :h) }.each do |u, res|
      assert_equal res, CATime.from_timesteps(1, unit: u).unit, "unit #{u}"
    end
  end

  # -- origin discipline ---------------------------------------------------

  def test_lossy_origin_raises
    dt = CA_INT64([0]).time(unit: :h)
    assert_raise(ArgumentError) do
      dt.timesteps(unit: "1 hour", origin: "2024-01-01T00:30:00Z")  # 30 min not on :h grid
    end
  end

  def test_calendar_origin_must_be_a_month_head
    # a calendar grid is addressed by month ordinal, so a day-of-month or
    # time-of-day phase names a bucket head that does not exist.  Dropping
    # it silently is the failure the fixed-length side already refuses.
    dt = CArray.time(["2020-03-05"], unit: :D)
    assert_raise(ArgumentError) { dt.floor(unit: "3 months", origin: "2000-12-15") }
    assert_raise(ArgumentError) { dt.timesteps(unit: "3 months", origin: "2000-12-15") }
    assert_raise(ArgumentError) do
      dt.floor(unit: "1 month", origin: Time.utc(2024, 5, 17, 13, 45))
    end
    assert_raise(ArgumentError) do
      dt.floor(unit: "3 months", origin: "2000-12-01T00:00:00+09:00")   # 11-30 15:00Z
    end
    assert_equal "2020-03-01", dt.floor(unit: "3 months", origin: "2000-12-01")[0].to_s
  end

  def test_calendar_origin_accepts_a_month_head_scalar
    dt = CArray.time(["2020-03-05"], unit: :D)
    head = CArray.time(["2000-12-01"], unit: :M)[0]
    assert_equal "2020-03-01", dt.floor(unit: "3 months", origin: head)[0].to_s
    off = CArray.time(["2000-12-15"], unit: :D)[0]
    assert_raise(ArgumentError) { dt.floor(unit: "3 months", origin: off) }
  end

  def test_year_storage_origin_must_start_in_january
    # a :Y tick starts in January, so a July phase cannot be stored on it --
    # the month used to be dropped as quietly as the day was.
    y = CArray.time(["2020-03-05"], unit: :Y)
    assert_raise(ArgumentError) { y.floor(unit: "1 year", origin: "2000-07-01") }
    assert_equal "2020", y.floor(unit: "1 year", origin: "2000-01-01")[0].to_s
    # a :D-stored array keeps the civil path, where a July phase is fine
    d = CArray.time(["2024-03-01"], unit: :D)
    assert_equal [-1], d.timesteps(unit: "1 year", origin: "2024-07-01").to_a
  end

  def test_integer_origin_rejected
    dt = CA_INT64([0]).time(unit: :h)
    assert_raise(ArgumentError) { dt.timesteps(unit: :h, origin: 100) }
  end

  def test_a_calendar_element_origin_on_a_fixed_grid
    # A calendar element names an instant -- the first midnight of its
    # granule -- so it is a bucket head like any other, and the fixed path
    # reads it the way the calendar path always did.  It used to be turned
    # away as having "no exact seconds", which is true of a month-long
    # duration but not of a month's head.
    h = CArray.time(["2020-08-15T05:00:00Z"], unit: :h)
    m = CArray.time("2000-01-01", unit: :M)[0]
    y = CArray.time("2000-06-01", unit: :Y)[0]           # -> 2000-01-01
    assert_equal h.timesteps(unit: "1 hour", origin: "2000-01-01").to_a,
                 h.timesteps(unit: "1 hour", origin: m).to_a
    assert_equal h.timesteps(unit: "6 hours", origin: "2000-01-01").to_a,
                 h.timesteps(unit: "6 hours", origin: y).to_a
    assert_equal ["2020-08-15T00:00:00Z"],
                 h.floor(unit: "1 day", origin: m).strftime("%FT%TZ").to_a

    # a month head is still not on a week grid, and a bare Integer is still
    # ambiguous -- accepting the element changes neither
    assert_raise(ArgumentError) do
      CA_INT64([0]).time(unit: :W).timesteps(unit: "1 week", origin: m)
    end
    assert_raise(ArgumentError) { h.timesteps(unit: "1 hour", origin: 100) }
  end

  # -- (bucket, storage) acceptance table ----------------------------------

  def test_finer_bucket_on_whole_multiple_storage
    # minute bucket on hour storage: an hour is 60 whole minutes, so every
    # element sits on the minute grid and its timestep is a plain widening.
    dt = CA_INT64([0, 1, -2]).time(unit: :h)
    assert_equal [0, 60, -120], dt.timesteps(unit: "1 minute").to_a
    # already on the finer grid: floor / ceil are the identity, and every
    # element is on-grid.
    assert_equal [0, 1, -2], dt.floor(unit: "1 minute").ticks.to_a
    assert_equal [0, 1, -2], dt.ceil(unit: "1 minute").ticks.to_a
    assert_equal [true, true, true], dt.is_righttime(unit: "1 minute").to_a
  end

  def test_finer_bucket_with_off_storage_origin
    # the origin is resolved on the bucket grid, not the storage grid, so a
    # phase finer than the storage tick is usable here.
    dt = CA_INT64([0, 1]).time(unit: :h)
    assert_equal [-30, 30], dt.timesteps(unit: "1 minute", origin: "1970-01-01 00:30").to_a
  end

  def test_partial_multiple_step_raises
    # neither tick is a whole multiple of the other: no integer timestep
    assert_raise(ArgumentError) { CA_INT64([0]).time(unit: :h).timesteps(unit: "7 minutes") }
    assert_raise(ArgumentError) do
      CA_INT64([0]).time(unit: "90 minutes").timesteps(unit: "1 hour")
    end
  end

  def test_month_step_on_week_storage_raises
    assert_raise(ArgumentError) { CA_INT64([0]).time(unit: :W).floor(unit: "1 month") }
  end

  # -- calendar path (civil-date algebra) ----------------------------------

  def test_civil_floor_month_and_year
    dt = CArray.time(
      CA_OBJECT(["2024-01-15T10:00:00Z", "2024-02-01T00:00:00Z",
                 "2024-02-28T23:59:59Z", "2023-12-31T00:00:00Z"]), unit: :s)
    assert_equal ["2024-01-01", "2024-02-01", "2024-02-01", "2023-12-01"],
                 dt.floor(unit: "1 month").to_time.to_a.map { |t| t.strftime("%F") }
    assert_equal ["2024-01-01", "2024-01-01", "2024-01-01", "2023-01-01"],
                 dt.floor(unit: "1 year").to_time.to_a.map { |t| t.strftime("%F") }
  end

  def test_civil_timesteps_is_months_since_epoch
    dt = CArray.time(
      CA_OBJECT(["2024-01-15T00:00:00Z", "2024-02-01T00:00:00Z",
                 "2023-12-31T00:00:00Z"]), unit: :s)
    # months since 1970-01: 2024-01 = 648, 2024-02 = 649, 2023-12 = 647
    assert_equal [648, 649, 647], dt.timesteps(unit: "1 month").to_a
    # quarters anchored at Jan 2024
    assert_equal [0, 0, -1], dt.timesteps(unit: "3 months", origin: "2024-01-01").to_a
  end

  def test_civil_ceil_and_is_righttime
    dt = CArray.time(
      CA_OBJECT(["2024-01-15T00:00:00Z", "2024-02-01T00:00:00Z"]), unit: :s)
    assert_equal ["2024-02-01", "2024-02-01"],
                 dt.ceil(unit: "1 month").to_time.to_a.map { |t| t.strftime("%F") }
    assert_equal [false, true], dt.is_righttime(unit: "1 month").to_a  # only Feb-01 on a boundary
  end

  def test_civil_round_nearest_by_tick_distance
    dt = CArray.time(
      CA_OBJECT(["2024-01-15T00:00:00Z",   # 14d into Jan -> Jan (14 < 17)
                 "2024-02-28T00:00:00Z",   # 27d into Feb -> Mar (2 < 27)
                 "2023-12-31T00:00:00Z"]), unit: :s)  # 1d from Jan -> Jan 2024
    assert_equal ["2024-01-01", "2024-03-01", "2024-01-01"],
                 dt.round(unit: "1 month").to_time.to_a.map { |t| t.strftime("%F") }
  end

  def test_civil_round_trips_from_timesteps
    dt = CArray.time(
      CA_OBJECT(["2024-01-15T00:00:00Z", "2023-06-10T00:00:00Z"]), unit: :s)
    k  = dt.timesteps(unit: "1 month")
    back = CATime.from_timesteps(k, unit: "1 month")
    assert_equal dt.floor(unit: "1 month").to_time.to_a, back.to_time.to_a
    assert_equal "2024-03", CATime.from_timesteps(650, unit: "1 month").to_s
  end

  def test_civil_pre_epoch_month_floor
    dt = CArray.time(CA_OBJECT(["1969-03-15T00:00:00Z"]), unit: :D)
    assert_equal ["1969-03-01"], dt.floor(unit: "1 month").to_time.to_a.map { |t| t.strftime("%F") }
    assert_equal [-10], dt.timesteps(unit: "1 month").to_a  # 1969-03 = 1970-01 minus 10 months
  end

  # -- mask propagation ----------------------------------------------------

  def test_mask_propagates
    m = CA_INT64([0, 1, 2, 3]).time(unit: :h)
    m.parent[1] = UNDEF
    idx = m.timesteps(unit: "2 hours")
    assert_equal [false, true, false, false], idx.is_masked.to_a
    assert_equal [0, 1, 1], idx[idx.is_not_masked].to_a
  end

  # -- overflow hardening (fine units raise, not silently wrap) ------------

  MAX64 = 2**63 - 1

  def test_round_ceil_head_overflow_raises_but_floor_fits
    a = CA_INT64([MAX64 - 10, MAX64]).time(unit: :ns)
    assert_raise(RangeError) { a.round(unit: "1 second") }
    assert_raise(RangeError) { a.ceil(unit: "1 second") }
    assert_nothing_raised { a.floor(unit: "1 second") }
  end

  def test_round_no_spurious_overflow_when_result_fits
    b = CA_INT64([4_600_000_000_000_000_000]).time(unit: :ns)
    assert_nothing_raised { b.round(unit: "1 second") }
  end

  def test_far_origin_overflow_raises
    b = CA_INT64([MAX64]).time(unit: :ns)
    far = CATime.wrap(CA_INT64([-(2**62)]), unit: :ns)[0]
    assert_raise(RangeError) { b.timesteps(unit: "1 second", origin: far) }
  end

  def test_step_ticks_overflow_raises
    # 1 hour in attoseconds exceeds int64
    assert_raise(RangeError) { CA_INT64([0]).time(unit: :as).timesteps(unit: "1 hour") }
  end

  def test_civil_ticks_per_day_overflow_raises
    # month bucket on attosecond storage: ticks-per-day exceeds int64
    assert_raise(RangeError) { CA_INT64([0]).time(unit: :as).floor(unit: "1 month") }
  end

  def test_coarse_unit_path_has_no_guard_overhead
    a = CA_INT64([MAX64 / 2]).time(unit: :s)
    assert_nothing_raised { a.timesteps(unit: "1 hour") }
  end

  def test_overflow_guard_ignores_a_masked_extreme
    # A masked cell carries no time, so it must not decide the range the
    # guard checks: the same array raises unmasked.
    a = CA_INT64([0, MAX64]).time(unit: :ns)
    assert_raise(RangeError) { a.ceil(unit: "1 second") }
    a.ticks.mask = CA_BOOLEAN([false, true])
    assert_equal [0, UNDEF], a.ceil(unit: "1 second").ticks.to_a
  end

  def test_overflow_guard_on_an_all_masked_or_empty_array
    # Nothing to bound, so nothing to guard -- and no Integer(UNDEF).
    a = CA_INT64([7, 8]).time(unit: :ns)
    a.ticks.mask = CA_BOOLEAN([true, true])
    assert_equal [UNDEF, UNDEF], a.timesteps(unit: "1 second").to_a
    assert_equal [UNDEF, UNDEF], a.floor(unit: "1 second").ticks.to_a
    assert_equal [], CArray.int64(0).time(unit: :ns).floor(unit: "1 second").ticks.to_a
  end

  # -- categorize composition (period buckets -> categorical) --------------

  def test_floor_categorize_composition
    dt = CArray.time(
      CA_OBJECT(["2024-01-15", "2024-01-20", "2024-02-03",
                 "2024-01-08", "2024-03-01"]), unit: :D)
    cat = dt.floor(unit: "1 month").categorize(sort_labels: true)
    assert_instance_of CACategorical, cat
    assert_equal [0, 0, 1, 0, 2], cat.codes.to_a
    assert_equal ["2024-01-01", "2024-02-01", "2024-03-01"],
                 cat.labels.map { |s| s.to_time.strftime("%F") }
    counts = CA_DOUBLE([1, 1, 1, 1, 1]).group_by_category(cat).sum
    assert_equal [3.0, 1.0, 1.0], counts.to_a
  end

  # -- algebraic invariants (property pins) --------------------------------

  def _prop_dt(unit)
    CArray.time(
      CA_OBJECT(["1969-11-07T03:17:00Z", "1970-01-01T00:00:00Z",
                 "2024-02-29T13:45:30Z", "2024-03-01T00:00:00Z",
                 "2024-07-04T18:00:00Z"]), unit: unit)
  end

  def test_invariant_floor_bounds_and_bucket_width
    dt = _prop_dt(:s)
    ["3 hours", "1 day", "1 month", "1 year"].each do |s|
      fl, ce = dt.floor(unit: s), dt.ceil(unit: s)
      assert (dt.parent >= fl.parent).all, "floor <= dt (#{s})"
      assert (dt.parent <= ce.parent).all, "dt <= ceil (#{s})"
    end
  end

  def test_invariant_floor_idempotent_and_is_righttime
    dt = _prop_dt(:s)
    ["3 hours", "1 day", "1 month"].each do |s|
      fl = dt.floor(unit: s)
      assert_equal dt.timesteps(unit: s).to_a, fl.timesteps(unit: s).to_a, "floor idempotent (#{s})"
      assert (fl.is_righttime(unit: s)).all, "floor lands on grid (#{s})"
      assert_equal fl.parent.to_a, fl.floor(unit: s).parent.to_a, "floor(floor) == floor (#{s})"
    end
  end

  def test_invariant_round_between_floor_and_ceil
    dt = _prop_dt(:s)
    ["3 hours", "1 day", "1 month"].each do |s|
      r, fl, ce = dt.round(unit: s).parent.to_a, dt.floor(unit: s).parent.to_a, dt.ceil(unit: s).parent.to_a
      r.each_index { |i| assert [fl[i], ce[i]].include?(r[i]), "round in {floor,ceil} (#{s})" }
    end
  end

  def test_invariant_timesteps_monotonic
    dt = CArray.time_series("1969-12-30T00:00:00Z", count: 200, unit: :h)  # crosses epoch
    ["1 hour", "3 hours", "1 day", "1 month"].each do |s|
      idx = dt.timesteps(unit: s).to_a
      assert idx.each_cons(2).all? { |a, b| a <= b }, "timesteps monotonic (#{s})"
    end
  end

  def test_invariant_roundtrip_from_timesteps
    dt = _prop_dt(:h)
    ["1 hour", "6 hours", "1 day", "1 week", "2 weeks", "1 month", "1 year"].each do |s|
      k = dt.timesteps(unit: s)
      back = CATime.from_timesteps(k, unit: s)
      assert_equal dt.floor(unit: s).to_time.to_a, back.to_time.to_a, "roundtrip (#{s})"
    end
  end

  def test_civil_floor_matches_ruby_date_over_wide_range
    require "date"
    days = (-1_800_000..1_800_000).step(97).to_a
    dt = CA_INT64(days).time(unit: :D)
    fl_m = dt.floor(unit: "1 month").to_time.to_a
    fl_y = dt.floor(unit: "1 year").to_time.to_a
    days.each_with_index do |dd, i|
      d = Date.jd(2440588 + dd, Date::GREGORIAN)  # proleptic Gregorian, matches civil
      assert_equal [d.year, d.month, 1], [fl_m[i].year, fl_m[i].month, fl_m[i].day], "month #{d}"
      assert_equal [d.year, 1, 1],       [fl_y[i].year, fl_y[i].month, fl_y[i].day], "year #{d}"
    end
  end

  def test_seven_days_differs_from_one_week
    # week bucket defaults to ISO Monday; "7 days" defaults to the epoch (Thursday)
    dt = CArray.time_series("2024-03-13", count: 5, unit: :D)
    assert_not_equal dt.floor(unit: "1 week").parent.to_a, dt.floor(unit: "7 days").parent.to_a
  end

  # -- civil-date field accessors ------------------------------------------

  def test_field_accessors_match_time_for_fixed_units
    require "time"
    require "date"
    strs = ["2024-02-29T13:45:30Z", "1969-12-31T23:59:59Z",
            "2000-01-01T00:00:00Z", "1900-03-01T00:00:00Z"]  # incl pre-epoch, leap edges
    dt = CArray.time(CA_OBJECT(strs), unit: :s)
    strs.each_with_index do |s, i|
      t = Time.parse(s).utc
      assert_equal [t.year, t.month, t.day], [dt.year.to_a[i], dt.month.to_a[i], dt.day.to_a[i]], s
      assert_equal [t.hour, t.min, t.sec], [dt.hour.to_a[i], dt.minute.to_a[i], dt.second.to_a[i]], s
      assert_equal [t.wday, t.yday], [dt.weekday.to_a[i], dt.yday.to_a[i]], s
      assert_equal Date.leap?(t.year), dt.is_leap.to_a[i], s
    end
  end

  def test_nxbase_field_accessors_fold_count
    # 10-minute storage: hour/minute fields must fold the count
    dt = CArray.time_series("2024-06-15T08:00:00Z", count: 4, unit: "10 minutes")
    assert_equal [8, 8, 8, 8],    dt.hour.to_a
    assert_equal [0, 10, 20, 30], dt.minute.to_a
    assert_equal [2024, 2024, 2024, 2024], dt.year.to_a
    assert_equal [15, 15, 15, 15], dt.day.to_a
  end

  def test_month_storage_fields_are_exact
    m = CA_INT64([648, 650, 647, 0]).time(unit: :M)  # 2024-01, 2024-03, 2023-12, 1970-01
    assert_equal [2024, 2024, 2023, 1970], m.year.to_a
    assert_equal [1, 3, 12, 1],            m.month.to_a
    assert_equal [1, 1, 1, 1],             m.day.to_a
    assert_equal [0, 0, 0, 0],             m.hour.to_a
    assert_equal [1, 5, 5, 4],             m.weekday.to_a  # weekday of the 1st
  end

  def test_year_storage_fields
    y = CA_INT64([54, 0, -1]).time(unit: :Y)  # 2024, 1970, 1969
    assert_equal [2024, 1970, 1969], y.year.to_a
    assert_equal [true, false, false],          y.is_leap.to_a  # 2024 is a leap year
  end

  def test_subresolution_fields_collapse_to_zero
    d = CArray.time(CA_OBJECT(["2024-06-15"]), unit: :D)
    assert_equal [0], d.hour.to_a
    assert_equal [0], d.minute.to_a
    assert_equal [0], d.second.to_a
  end

  def test_field_accessor_mask_propagates
    dt = CArray.time(CA_OBJECT(["2024-01-01", "2024-06-15", "2024-12-31"]), unit: :D)
    dt.parent[1] = UNDEF
    assert_equal [false, true, false], dt.year.is_masked.to_a   # civil path
    assert_equal [false, true, false], dt.hour.is_masked.to_a   # zero (collapse) path preserves mask too
  end

  # -- Face-selected views (upstream double-lift fix) ----------------------

  def test_boolean_selected_face_has_int64_parent_and_ops_work
    dt = CArray.time_series("2024-01-01T00:00:00Z", count: 6, unit: :h)
    sel = dt[dt.parent.lt(dt.parent[4])]        # boolean-selected CATime
    assert_not_kind_of CATime, sel.parent
    assert_equal [0, 1, 2, 3], sel.timesteps(unit: "1 hour", origin: "2024-01-01T00:00:00Z").to_a
    assert_equal [2024, 2024, 2024, 2024], sel.year.to_a
    assert_instance_of CATime, sel.floor(unit: "1 day")
  end

  # -- crown jewel: obs / forecast integer matching ------------------------

  def test_dense_positional_addressing
    obs_vt  = CArray.time_series("2024-01-01T02:00:00Z", count: 4, unit: :h)   # 02..05Z
    fcst_vt = CArray.time_series("2024-01-01T00:00:00Z", count: 8, unit: :h)   # 00..07Z
    oidx = obs_vt.timesteps(unit: "1 hour")     # default origin (epoch): absolute hour index
    fidx = fcst_vt.timesteps(unit: "1 hour")
    assert obs_vt.is_righttime(unit: "1 hour").all

    k0, k1 = oidx.min, oidx.max            # grid domain = scatter (obs) range
    grid = CArray.float64(k1 - k0 + 1) { UNDEF }
    grid[oidx - k0] = CA_DOUBLE([20.0, 21.0, 22.0, 23.0])

    inr = fidx.ge(k0) & fidx.le(k1)        # clip gather into the grid domain
    matched = CArray.float64(fidx.size) { UNDEF }
    matched[inr] = grid[(fidx - k0)[inr]]

    assert_equal [true, true, false, false, false, false, true, true], matched.is_masked.to_a
    assert_equal [20.0, 21.0, 22.0, 23.0], matched[matched.is_not_masked].to_a
  end
end

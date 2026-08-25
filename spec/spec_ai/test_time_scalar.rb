# frozen_string_literal: true
#
# CATime::Element / CATimedelta::Element — S1 delegation + display.
#
# The scalar delegates calendar breakdown to Ruby Date / Time (one object's
# cost per value), but exactly: :M / :Y decode via Date#next_month / #next_year
# (no 30.5-day drift), fixed units via exact Rational-second Time.at.  to_s is
# unit-aware so (value, unit) stays recoverable.  CATimedelta#to_seconds is
# exact for fixed units and raises for calendar units.
#
# See devel/PROPOSAL_DATETIME64_SCALAR.md (S1).

require "test/unit"
require "carray"
require "date"
require "time"

class TestDatetimeScalar < Test::Unit::TestCase
  S = CATime::Element
  T = CATimedelta::Element

  # -- exact calendar decode (the drift fix) -------------------------------

  def test_month_scalar_decodes_exactly
    # 650 months since 1970-01 = 2024-03 (the old 30.5-day path drifted here)
    s = S.new(650, :M)
    assert_equal "2024-03-01T00:00:00Z", s.to_time.iso8601
    assert_equal Date.new(2024, 3, 1),   s.to_date
    assert_equal 2024,                   s.to_time.year
    assert_equal 3,                      s.to_time.month
  end

  def test_year_scalar_decodes_exactly
    assert_equal "2024-01-01T00:00:00Z", S.new(54, :Y).to_time.iso8601
    assert_equal 1969, S.new(-1, :Y).to_time.year   # pre-epoch
  end

  # -- proleptic Gregorian consistency (to_date must not leak Date::ITALY) ---
  # CATime is proleptic Gregorian throughout; before 1582-10-15 the default
  # Date start (ITALY) would make to_date disagree with to_time / field accessors.

  def test_to_date_is_proleptic_gregorian_pre_1582_day_unit
    e = CATime.wrap(CA_INT64([-141428]), unit: :D)   # JD ~2299150, straddles the cutover
    iso = e[0].to_time.strftime("%Y-%m-%d")
    assert_equal "1582-10-14", iso
    assert_equal iso, e[0].to_date.to_s                              # scalar to_date
    assert_equal iso, e.to_date[0].to_s                              # array to_date
    assert_equal [1582, 10, 14], [e.year[0], e.month[0], e.day[0]]   # field accessors
  end

  def test_to_date_matches_to_time_instant_pre_1582_year_unit
    # The civil labels coincide here, so compare the underlying instant via JD.
    e = CATime.wrap(CA_INT64([1400 - 1970]), unit: :Y)
    jd_from_date = e[0].to_date.jd
    jd_from_time = (e[0].to_time.to_i / 86400) + 2440588
    assert_equal jd_from_time, jd_from_date
    assert_equal Date.new(1400, 1, 1, Date::GREGORIAN).jd, jd_from_date
  end

  def test_month_scalar_matches_date_over_range
    [-600, -1, 0, 1, 650, 12_000].each do |v|
      exp = Date.new(1970, 1, 1).next_month(v)
      assert_equal [exp.year, exp.month, 1],
                   [S.new(v, :M).to_time.year, S.new(v, :M).to_time.month, S.new(v, :M).to_time.day], v
    end
  end

  def test_fixed_unit_is_exact_utc
    assert_equal "2024-01-01T00:00:00Z", S.new(1_704_067_200, :s).to_time.iso8601
    assert_equal "2024-01-01T00:00:00.500000000Z",
                 S.new(1_704_067_200_500_000_000, :ns).to_time.iso8601(9)
    assert_equal Time, S.new(0, :us).to_time.class
    assert_equal 0, S.new(0, :s).to_time.utc_offset   # UTC, not local
  end

  # -- unit-aware to_s (granularity is recoverable) ------------------------

  def test_to_s_is_unit_aware
    assert_equal "2024",       S.new(54, :Y).to_s
    assert_equal "2024-03",    S.new(650, :M).to_s
    assert_equal "2024-03-01", S.new(19783, :D).to_s
    assert_equal "2024-01-01T00:00:00Z", S.new(1_704_067_200, :s).to_s
    # a :M and a :D at the same instant print differently
    assert_not_equal S.new(650, :M).to_s, S.new(19783, :D).to_s
  end

  def test_inspect_carries_raw_value_and_unit
    assert_equal "#<CATime::Element 2024-03 (650M)>", S.new(650, :M).inspect
  end

  def test_to_date_floors_subday
    s = CArray.time_series("2024-06-15T18:30:00", count: 1, unit: :s)[0]
    assert_equal Date.new(2024, 6, 15), s.to_date  # time-of-day floored away
  end

  def test_to_datetime
    assert_kind_of DateTime, S.new(650, :M).to_datetime
  end

  # -- CATimedelta#to_seconds: exact vs raise ------------------------------

  def test_timedelta_to_seconds_exact_for_fixed
    assert_equal Rational(90), T.new(90, :s).to_seconds
    assert_equal Rational(90, 1000), T.new(90, :ms).to_seconds
    assert_equal Rational(7 * 86400), T.new(1, :W).to_seconds
  end

  def test_timedelta_to_seconds_raises_for_calendar
    assert_raise(ArgumentError) { T.new(1, :M).to_seconds }
    assert_raise(ArgumentError) { T.new(1, :Y).to_seconds }
  end

  def test_timedelta_to_seconds_approx_is_explicit
    assert_in_delta 30.5 * 86400, T.new(1, :M).to_seconds_approx, 1e-6
  end

  # -- S3: cross-unit comparison, eql? / hash ------------------------------

  def test_cross_unit_equality_by_instant
    # same instant, different unit -> == true (Comparable via <=>)
    assert_equal S.new(1_709_251_200, :s), S.new(1_709_251_200_000, :ms)
    assert_equal S.new(650, :M), S.new(19783, :D)   # 2024-03 == 2024-03-01
    assert S.new(650, :M) < S.new(19800, :D)         # 2024-03 < a later day
  end

  def test_cross_group_datetime_always_comparable
    # :M vs :W reconcile through :D (both reach it exactly), never raise
    assert_not_nil (S.new(650, :M) <=> S.new(2818, :W))
  end

  def test_compare_with_time
    assert S.new(650, :M) < Time.utc(2024, 4, 1)
    assert_equal 0, (S.new(650, :M) <=> Time.utc(2024, 3, 1))
    assert_nil (S.new(0, :s) <=> "not a time")
  end

  def test_eql_and_hash_are_unit_strict
    # == is by instant, but eql? / hash key a Hash by (value, unit)
    refute S.new(1_709_251_200, :s).eql?(S.new(1_709_251_200_000, :ms))
    h = { S.new(650, :M) => :x }
    assert_equal :x, h[S.new(650, :M)]
    assert_nil h[S.new(19783, :D)]        # same instant, different unit -> different key
  end

  def test_timedelta_cross_group_is_incomparable
    assert_nil (T.new(1, :M) <=> T.new(60, :s))   # no order between month and second duration
    refute (T.new(1, :M) == T.new(60, :s))
    assert_raise(ArgumentError) { T.new(1, :M) < T.new(60, :s) }
    # same group cross-unit compares fine
    assert_equal T.new(2, :h), T.new(120, :m)
  end

  # -- S2: scalar arithmetic (unit-preserving ops Time can't give) ---------

  def test_datetime_diff_same_group_finer_unit
    a = S.new(19797, :D); b = S.new(19723, :D)   # 2024-03-15, 2024-01-01
    d = a - b
    assert_instance_of T, d
    assert_equal [74, :D], [d.value, d.unit.base]
    # mixed fixed units -> finer
    dh = S.new(19723 * 24 + 5, :h) - S.new(19723, :D)
    assert_equal [5, :h], [dh.value, dh.unit.base]
    # calendar
    dm = S.new(650, :M) - S.new(648, :M)
    assert_equal [2, :M], [dm.value, dm.unit.base]
  end

  def test_datetime_diff_cross_group_is_fixed_unit
    # a :M/:Y difference only arises from two calendar operands; a calendar vs
    # fixed difference is in the fixed unit (E)
    d = S.new(650, :M) - S.new(19723, :D)         # 2024-03 - 2024-01-01
    assert_equal [60, :D], [d.value, d.unit.base]      # Jan(31)+Feb(29) = 60 days
  end

  def test_datetime_plus_timedelta_keeps_datetime_unit
    # dt is the anchor: the result keeps its unit; a finer duration truncates
    # into it (5 h is under a day -> +0; 30 h -> +1 day).
    r = S.new(19723, :D) + T.new(5, :h)           # 2024-01-01 + 5h -> same day
    assert_equal [19723, :D], [r.value, r.unit.base]
    r2 = S.new(19723, :D) + T.new(30, :h)         # +30h -> +1 day
    assert_equal [19724, :D], [r2.value, r2.unit.base]
    # a coarser duration widens exactly (calendar): 2024-01 + 1y = 2025-01
    ry = S.new(648, :M) + T.new(1, :Y)
    assert_equal [660, :M], [ry.value, ry.unit.base]
  end

  def test_datetime_plus_timedelta_cross_group_raises
    assert_raise(ArgumentError) { S.new(0, :s) + T.new(1, :M) }  # calendar step
    assert_raise(TypeError)     { S.new(0, :s) + S.new(1, :s) }  # time + time
  end

  def test_diff_roundtrip_is_the_same_instant
    a = S.new(650, :M); b = S.new(19723, :D)
    assert_equal a.to_time, (b + (a - b)).to_time           # cross-group: same instant
    a2 = S.new(19797, :D); b2 = S.new(19723, :D)
    assert_equal a2, b2 + (a2 - b2)                         # same-unit: exact ==
  end

  def test_timedelta_arithmetic
    assert_equal [330, :m], [(T.new(5, :h) + T.new(30, :m)).value, (T.new(5, :h) + T.new(30, :m)).unit.base]
    assert_equal [6, :h],   [(T.new(2, :h) * 3).value, (T.new(2, :h) * 3).unit.base]
    assert_equal Rational(3), T.new(6, :h) / T.new(2, :h)
    assert_equal [2, :h],   [(T.new(6, :h) / 3).value, (T.new(6, :h) / 3).unit.base]
    assert_raise(ArgumentError) { T.new(1, :M) + T.new(1, :s) }   # cross-group scale
  end

  # -- S0: scale vs instant unit algebra -----------------------------------

  def test_convert_scale_cross_group_raises
    # a duration :M has no fixed ratio to days
    assert_raise(ArgumentError) do
      CATimeUnitAlgebra.convert_scale!(CA_INT64([1]), :M, :s)
    end
  end

  def test_convert_instant_calendar_widens_to_fixed
    # a time :M(650)=2024-03 widens exactly to :s = 2024-03-01 00:00 UTC
    r = CATimeUnitAlgebra.convert_instant!(CA_INT64([650]), :M, :s)
    assert_equal [Time.utc(2024, 3, 1).to_i], r.to_a
    # :Y widens too
    r2 = CATimeUnitAlgebra.convert_instant!(CA_INT64([54]), :Y, :D)
    assert_equal [Date.new(2024, 1, 1).jd - Date.new(1970, 1, 1).jd], r2.to_a
  end

  def test_convert_instant_fixed_coarsens_on_boundary_else_raises
    # 2024-03-01 in seconds -> :M exactly = month 650
    onb = Time.utc(2024, 3, 1).to_i
    assert_equal [650], CATimeUnitAlgebra.convert_instant!(CA_INT64([onb]), :s, :M).to_a
    # mid-month -> raises
    off = Time.utc(2024, 3, 15).to_i
    assert_raise(ArgumentError) { CATimeUnitAlgebra.convert_instant!(CA_INT64([off]), :s, :M) }
  end

  def test_convert_instant_week_cross_calendar_raises
    assert_raise(ArgumentError) { CATimeUnitAlgebra.convert_instant!(CA_INT64([650]), :M, :W) }
  end

  # -- scalar round-trips storage (unchanged) ------------------------------

  def test_scalar_round_trips_through_store
    dt = CArray.time_series("2024-01-01T00:00:00Z", count: 3, unit: :h)
    dt[0] = dt[2]
    assert_equal dt[2].value, dt[0].value
  end
end

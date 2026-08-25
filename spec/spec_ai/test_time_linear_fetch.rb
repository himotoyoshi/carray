# frozen_string_literal: true
#
# CATime#linear_fetch / CATimedelta#linear_fetch — grid-preserving re-lift.
#
# linear_fetch returns a value (not a position), so it re-lifts the Face: the
# result is a CATime / CATimedelta in *self's* unit.  The array's grid is the
# output grid, so an instant landing between two ticks is rounded to the
# nearest one; widen the grid with to_unit first when the interpolation needs
# finer resolution.  An out-of-range address becomes UNDEF (int64 storage has
# no NaN to carry a sentinel) and a masked address stays UNDEF.
#
# See devel/PROPOSAL_LINEAR_FETCH_FACE_RELIFT.md.

require "test/unit"
require "carray"

class TestTimeLinearFetch < Test::Unit::TestCase

  # -- 1. grid preservation ------------------------------------------------

  def test_output_is_a_catime_in_self_unit
    t = CArray.time_series("2024-06-15T00:00", count: 7, unit: "2 hours")
    r = t.linear_fetch(CA_FLOAT64([0.0, 1.0]))
    assert_instance_of CATime, r
    assert_equal t.unit, r.unit
    assert_equal 2,      r.unit.count
    assert_equal :h,     r.unit.base
  end

  # -- 2. exact interpolation (the midpoint lands on the grid) -------------

  def test_midpoint_on_grid_is_exact
    t = CArray.time(["2024-01-01", "2024-01-03", "2024-01-07"], unit: :D)
    r = t.linear_fetch(CA_FLOAT64([0.0, 0.5, 1.5]))
    # 19723, (19723+19725)/2 = 19724, (19725+19729)/2 = 19727
    assert_equal [19723, 19724, 19727], r.parent.to_a
  end

  # -- 3. off-grid rounds to self's grid; to_unit widens it first ----------

  def test_off_grid_rounds_to_the_storage_tick
    t = CArray.time_series("2024-06-15T00:00", count: 7, unit: "2 hours")
    # 0.25 / 0.75 of a 2-hour tick = 30 / 90 minutes, which the 2 h grid
    # cannot hold, so each rounds to the nearest tick.
    assert_equal [238668, 238669],
                 t.linear_fetch(CA_FLOAT64([0.25, 0.75])).parent.to_a
  end

  def test_to_unit_carries_the_sub_tick_precision
    t  = CArray.time_series("2024-06-15T00:00", count: 7, unit: "2 hours")
    tf = t.to_unit(:ms)
    r  = tf.linear_fetch(CA_FLOAT64([0.0, 0.25]))
    assert_equal tf.unit, r.unit
    assert_equal "2024-06-15T00:00:00.000Z", r[0].to_time.iso8601(3)
    assert_equal "2024-06-15T00:30:00.000Z", r[1].to_time.iso8601(3)
  end

  # -- 4. the two UNDEF sources ------------------------------------------

  def test_out_of_range_and_masked_address_both_yield_undef
    t = CArray.time_series("2024-06-15T00:00", count: 7, unit: "2 hours")
    addr = CA_FLOAT64([0.0, 0.5, 3.0, 9.0])   # 9.0 is beyond the axis
    addr[2] = UNDEF                            # undetermined query
    r = t.linear_fetch(addr)
    assert_equal [false, false, true, true], r.is_masked.to_a
    assert_equal 238668, r.parent[0]
  end

  def test_scalar_address_returns_an_element_and_nil_when_undetermined
    t = CArray.time_series("2024-06-15T00:00", count: 7, unit: "2 hours")
    s = t.linear_fetch(3.5)
    assert_instance_of CATime::Element, s
    assert_equal "2024-06-15T08:00:00Z", s.to_time.iso8601
    assert_nil t.linear_fetch(9.0)             # out of range
    masked = CA_FLOAT64([1.0]); masked[0] = UNDEF
    assert_nil t.linear_fetch(masked[0])       # undetermined query
  end

  # -- 5. rounding does not flip direction at the epoch -------------------

  def test_rounding_is_nearest_on_both_sides_of_the_epoch
    # Ticks straddling the epoch.  An int64 truncation rounds toward zero, so
    # it would answer -1 and 1 here -- 0.8 tick of error pulling toward
    # 1970-01-01 from both sides.  Nearest gives -2 and 2: the error never
    # depends on which side of the epoch the instant sits.
    pre  = CArray.time(["1969-12-30", "1970-01-01"], unit: :D)   # [-2, 0]
    post = CArray.time(["1970-01-01", "1970-01-03"], unit: :D)   # [0, 2]
    assert_equal [-2, -2], pre.linear_fetch(CA_FLOAT64([0.0, 0.1])).parent.to_a
    assert_equal [2, 2],   post.linear_fetch(CA_FLOAT64([0.9, 1.0])).parent.to_a
  end

  # -- 6. round-trip with linear_section ---------------------------------

  def test_round_trip_through_linear_section
    t = CArray.time_series("2024-06-15T00:00", count: 7, unit: "2 hours").to_unit(:h)
    v = CArray.time(["2024-06-15T03:00", "2024-06-15T09:00"], unit: :h)
    back = t.linear_fetch(t.linear_section(v))
    assert_instance_of CATime, back
    assert_equal t.unit, back.unit
    assert_equal v.parent.to_a, back.parent.to_a
  end

  def test_round_trip_on_a_calendar_axis_stays_on_the_month_grid
    # Both halves of the pair read the same storage grid, so the round trip
    # holds without picking an interpolation space for calendar units.
    m = CArray.time(["2024-01-01", "2024-03-01", "2024-07-01"], unit: :M)
    v = CArray.time(["2024-03-01", "2024-07-01"], unit: :M)
    back = m.linear_fetch(m.linear_section(v))
    assert_equal m.unit,        back.unit
    assert_equal v.parent.to_a, back.parent.to_a
  end

  # -- 7. CATimedelta is symmetric --------------------------------------

  def test_timedelta_keeps_its_unit
    td = CArray.time(["2024-01-02", "2024-01-05"], unit: :D) -
         CArray.time(["2024-01-01"], unit: :D)               # [1, 4] days
    r = td.linear_fetch(CA_FLOAT64([0.0, 1.0 / 3.0, 1.0]))
    assert_instance_of CATimedelta, r
    assert_equal td.unit, r.unit
    assert_equal [1, 2, 4], r.parent.to_a
  end

  def test_timedelta_out_of_range_is_undef_and_scalar_is_an_element
    td = CArray.time(["2024-01-02", "2024-01-05"], unit: :D) -
         CArray.time(["2024-01-01"], unit: :D)
    r = td.linear_fetch(CA_FLOAT64([0.5, 5.0]))
    assert_equal [false, true], r.is_masked.to_a
    assert_instance_of CATimedelta::Element, td.linear_fetch(0.5)
    assert_nil td.linear_fetch(5.0)
  end

  # -- 8. a non-orderable Face still refuses ----------------------------

  def test_categorical_face_still_raises
    c = CA_OBJECT(%w[a b c a]).categorize
    assert_raise(ArgumentError) { c.linear_fetch(0.5) }
  end

  # -- 9. CAFrame#fill(:linear) on a time column ------------------------

  def test_frame_fill_linear_interpolates_a_time_column
    t = CArray.time(["2024-01-01", "2024-01-02", "2024-01-03", "2024-01-05"], unit: :D)
    t[2] = UNDEF
    df = CAFrame.new("x" => CA_FLOAT64([0, 1, 2, 3]), "when" => t.copy).set_index("x")
    df.fill("when", :linear)
    col = df["when"]
    assert_instance_of CATime, col
    assert_equal t.unit, col.unit
    # x = 2 sits halfway between (1, 19724) and (3, 19727) -> 19725.5 -> 19726
    assert_equal [19723, 19724, 19726, 19727], col.parent.to_a
    assert_equal 0, col.count_masked   # the gap is filled, nothing left UNDEF
  end

  def test_frame_fill_linear_without_an_index_uses_the_cell_position
    t = CArray.time(["2024-01-01", "2024-01-02", "2024-01-03", "2024-01-05"], unit: :D)
    t[2] = UNDEF
    df = CAFrame.new("when" => t.copy)
    df.fill("when", :linear)
    assert_equal [19723, 19724, 19726, 19727], df["when"].parent.to_a
  end

  def test_frame_fill_linear_leaves_cells_outside_the_valid_span_undef
    t = CArray.time(["2024-01-01", "2024-01-02", "2024-01-03", "2024-01-04"], unit: :D)
    t[0] = UNDEF
    t[3] = UNDEF
    df = CAFrame.new("when" => t)
    df.fill("when", :linear)
    assert_equal [true, false, false, true], df["when"].is_masked.to_a
  end

  def test_frame_fill_linear_still_rejects_a_non_numeric_non_time_column
    df = CAFrame.new("s" => CA_OBJECT(%w[a b]))
    assert_raise(ArgumentError) { df.fill("s", :linear) }
  end

  def test_frame_fill_linear_numeric_column_is_unchanged
    df = CAFrame.new("v" => CA_FLOAT64([1, 2, UNDEF, 4]))
    df.fill("v", :linear)
    assert_equal [1.0, 2.0, 3.0, 4.0], df["v"].to_a
  end
end

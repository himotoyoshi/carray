# frozen_string_literal: true
#
# CATime / CATimedelta reductions — one rule: the output grid is the array's
# own unit.
#
# A centroid, a spread and an order statistic all report on `self.unit`,
# rounded to the nearest tick.  Precision is declared by the caller, before
# the reduction: `t.to_unit(:h).mean`.  Nothing auto-refines, so the range an
# array can hold is the range its reductions can answer in -- a 1600..2400
# daily series takes a mean, which the old refine-to-:ns rule could not.
#
# The prices of the rule are pinned here too: a spread on a coarse unit
# rounds hard (§5 of the proposal), and a calendar array reduces in month
# ordinals rather than in day space.
#
# See devel/PROPOSAL_TIME_REDUCTION_GRID_POLICY.md.

require "test/unit"
require "carray"
require "time"

class TestTimeReductionGrid < Test::Unit::TestCase

  # 2024-01-02, -09, -15, -30, 2024-02-05 as day ticks
  DAYS = %w[2024-01-02 2024-01-09 2024-01-15 2024-01-30 2024-02-05]

  def days
    CArray.time(DAYS, unit: :D)
  end

  def durations
    CA_INT64([0, 3, 7, 13, 28]).timedelta(unit: :D)
  end

  # -- 1. the output grid is self's unit -----------------------------------

  def test_time_flat_members_return_elements_on_selfs_unit
    t = days
    [:mean, :median].each do |op|
      r = t.send(op)
      assert_instance_of CATime::Element, r, op
      assert_equal :D, r.unit.base, op
      assert_equal 1, r.unit.count, op
    end
    [:stddev, :stddevp].each do |op|
      r = t.send(op)
      assert_instance_of CATimedelta::Element, r, op
      assert_equal :D, r.unit.base, op
    end
    assert_instance_of CATime::Element, t.percentile(50)
    assert_equal :D, t.percentile(50).unit.base
  end

  def test_time_per_axis_members_return_catime_on_selfs_unit
    t = CArray.time(%w[2024-06-15 2024-06-17 2024-06-19 2024-06-21],
                    unit: :D).reshape(2, 2)
    [t.mean(axis: 1), t.median(axis: 1), t.percentile(50, axis: 1)].each do |r|
      assert_instance_of CATime, r
      assert_equal :D, r.unit.base
    end
    [t.stddev(axis: 1), t.stddevp(axis: 1)].each do |r|
      assert_instance_of CATimedelta, r
      assert_equal :D, r.unit.base
    end
    assert_equal [Time.utc(2024, 6, 16), Time.utc(2024, 6, 20)],
                 t.mean(axis: 1).to_time.to_a
  end

  def test_timedelta_members_return_elements_on_selfs_unit
    td = durations
    [:sum, :mean, :median, :stddev, :stddevp].each do |op|
      r = td.send(op)
      assert_instance_of CATimedelta::Element, r, op
      assert_equal :D, r.unit.base, op
    end
    assert_instance_of CATimedelta::Element, td.percentile(50)
    assert_equal :D, td.percentile(50).unit.base
  end

  def test_timedelta_per_axis_members_return_catimedelta
    td = CA_INT64([[0, 4], [10, 20]]).timedelta(unit: :h)
    [td.mean(axis: 1), td.median(axis: 1), td.stddev(axis: 1),
     td.stddevp(axis: 1), td.percentile(50, axis: 1)].each do |r|
      assert_instance_of CATimedelta, r
      assert_equal :h, r.unit.base
    end
    assert_equal [2, 15], td.mean(axis: 1).ticks.to_a
  end

  def test_a_non_unit_count_survives_the_reduction
    t = CArray.time(%w[2024-01-01 2024-01-02], unit: "10 minutes")
    assert_equal 10, t.mean.unit.count
    assert_equal :m, t.mean.unit.base
  end

  # -- 2. a value on the grid comes back exactly ---------------------------

  def test_odd_count_median_is_the_element_itself
    t = days
    assert_equal t[2].value, t.median.value       # 2024-01-15, no interpolation
    assert_equal Time.utc(2024, 1, 15), t.median.to_time
  end

  def test_percentile_landing_on_a_tick_is_that_tick
    t = days
    assert_equal t[0].value,   t.percentile(0).value
    assert_equal t[-1].value,  t.percentile(100).value
    assert_equal t[1].value,   t.percentile(25).value    # 4 values: p25 = 2nd
  end

  def test_a_reduction_of_equal_instants_is_that_instant
    t = CArray.time(%w[2024-03-05 2024-03-05 2024-03-05], unit: :D)
    assert_equal Time.utc(2024, 3, 5), t.mean.to_time
    assert_equal 0, t.stddev.value                  # a zero spread stays zero
  end

  # -- 3. off-grid values round to the nearest tick ------------------------

  def test_off_grid_centroid_rounds_to_nearest_not_toward_zero
    # 19889.5 -> 19890 (the later day), not 19889
    t = CArray.time(%w[2024-06-15 2024-06-16], unit: :D)
    assert_equal Time.utc(2024, 6, 16), t.mean.to_time
  end

  def test_rounding_does_not_change_direction_across_the_epoch
    # Mirror-image inputs give mirror-image answers.  A truncating round would
    # pull both toward the epoch (-8 and 8) and so bias pre-epoch times later
    # and post-epoch times earlier.
    before = CA_INT64([-10, -7]).time(unit: :D)
    after  = CA_INT64([7, 10]).time(unit: :D)
    assert_equal(-9, before.mean.value)
    assert_equal 9, after.mean.value
    assert_equal before.mean.value, -after.mean.value
  end

  def test_per_axis_rounds_the_same_way_as_the_flat_form
    m = CA_INT64([[-10, -7], [7, 10]]).time(unit: :D)
    assert_equal [-9, 9], m.mean(axis: 1).ticks.to_a
  end

  # -- 4. a wide range is no longer a RangeError ---------------------------
  #
  # The old rule refined the output to :ns, which holds only ~292 years, so an
  # array whose own unit spans millennia could not be reduced at all.

  def test_wide_daily_ranges_reduce_instead_of_raising
    [["1970-01-01", "2200-01-01"],
     ["1600-01-01", "2400-01-01"],
     ["0001-01-01", "2000-01-01"]].each do |first, last|
      t = CArray.time_range(first, last, unit: :D)
      [:mean, :median].each do |op|
        r = t.send(op)
        assert_instance_of CATime::Element, r, "#{op} of #{first}..#{last}"
        assert_equal :D, r.unit.base
      end
      assert_instance_of CATimedelta::Element, t.stddev
    end
  end

  def test_the_answer_for_a_wide_range_is_the_midpoint
    t = CArray.time_range("1600-01-01", "2400-01-01", unit: :D)
    assert_equal Time.utc(2000, 1, 1), t.mean.to_time
  end

  # -- 5. a calendar array reduces in month ordinals -----------------------

  def test_calendar_centroid_stays_in_month_space
    m = CArray.time(%w[2024-01-01 2024-03-01], unit: :M)
    assert_equal [648, 650], m.ticks.to_a
    assert_equal :M, m.mean.unit.base
    assert_equal 649, m.mean.value
    assert_equal Time.utc(2024, 2, 1), m.mean.to_time
  end

  def test_day_space_is_reachable_by_declaring_the_day_grid
    # to_unit cannot widen a calendar unit into a fixed one (no fixed ratio),
    # so the day-space route rebuilds the array on the :D grid.
    m = CArray.time(%w[2024-01-01 2024-03-01], unit: :M)
    assert_raise(ArgumentError) { m.to_unit(:D) }
    d = CArray.time(m.to_time, unit: :D)
    assert_equal Time.utc(2024, 1, 31), d.mean.to_time
  end

  # -- 6. the members that used to fall through ----------------------------

  def test_members_that_used_to_raise_on_fixlen_now_answer
    t = days
    assert_instance_of CATimedelta::Element, t.stddevp
    assert_instance_of CATime::Element,      t.percentile(50)
    assert_equal 2, t.percentile(25, 75).size
    t.percentile(25, 75).each {|x| assert_instance_of CATime::Element, x }
    q = t.quantile
    assert_equal 5, q.size
    q.each {|x| assert_instance_of CATime::Element, x }
    assert_equal [t[0].value, t[-1].value], [q.first.value, q.last.value]
  end

  def test_members_that_used_to_return_plain_floats_now_carry_the_unit
    td = durations
    [:median, :stddev, :stddevp].each do |op|
      assert_instance_of CATimedelta::Element, td.send(op), op
    end
    assert_instance_of CATimedelta::Element, td.percentile(50)
    assert_equal 5, td.quantile.size
    td.quantile.each {|x| assert_instance_of CATimedelta::Element, x }
  end

  def test_multi_p_and_quantile_keep_the_plain_array_shapes
    t = CArray.time(%w[2024-06-15 2024-06-17 2024-06-19 2024-06-21],
                    unit: :D).reshape(2, 2)
    per_axis = t.percentile(25, 75, axis: 1)
    assert_instance_of Array, per_axis
    assert_equal 2, per_axis.size
    per_axis.each {|x| assert_instance_of CATime, x }
    q = t.quantile(axis: 1)
    assert_instance_of Array, q
    assert_equal 5, q.size
    q.each {|x| assert_instance_of CATime, x }
    # single p is unwrapped, as in the plain surface
    assert_instance_of CATime, t.percentile(50, axis: 1)
  end

  # -- 7. the contracts that do not change ---------------------------------

  def test_sum_and_variance_still_refuse_for_catime
    t = days
    assert_raise(TypeError) { t.sum }
    assert_raise(TypeError) { t.variance }
    assert_raise(TypeError) { t.variancep }        # was a raw kernel error
  end

  def test_timedelta_variance_refuses_like_time_does
    # The one member of the family that cannot carry a unit: its value is in
    # squared ticks, and no Face represents squared time.  CATime has always
    # refused it for that reason; CATimedelta does too rather than handing
    # back a bare number whose unit is squared and unrecorded.  The spread as
    # a duration is #stddev.
    td = durations
    assert_raise(TypeError) { td.variance }
    assert_raise(TypeError) { td.variancep }
    assert_kind_of CATimedelta::Element, td.stddev
  end

  def test_extremes_are_elements_and_untouched_by_the_policy
    t = days
    assert_equal Time.utc(2024, 1, 2),  t.min.to_time
    assert_equal Time.utc(2024, 2, 5),  t.max.to_time
    lo, hi = t.minmax
    assert_instance_of CATime::Element, lo
    assert_instance_of CATime::Element, hi
    assert_equal [t.min.value, t.max.value], [lo.value, hi.value]
  end

  def test_empty_and_fully_masked_reductions_stay_undef
    empty = CArray.time([], unit: :D)
    assert_equal UNDEF, empty.mean
    masked = days
    masked[nil] = UNDEF
    [:mean, :median, :stddev].each do |op|
      assert_equal UNDEF, masked.send(op), op
    end
    assert_equal UNDEF, masked.percentile(50)
  end

  def test_masked_cells_are_excluded_and_min_count_still_applies
    t = days
    t[0] = UNDEF
    # of the remaining four: (19737 + 19752) / 2 = 19744.5 -> 19745
    assert_equal Time.utc(2024, 1, 23), t.median.to_time
    assert_equal UNDEF, t.mean(min_count: 5)
    assert_instance_of CATime::Element, t.mean(min_count: 4)
  end

  def test_a_fully_masked_fiber_reduces_to_an_undef_cell
    t = CArray.time_range("2024-01-01", "2024-01-06", unit: :D).reshape(2, 3)
    t[0, nil] = UNDEF
    [t.mean(axis: 1), t.median(axis: 1), t.percentile(50, axis: 1)].each do |r|
      assert_equal [true, false], r.mask.to_a
      assert_equal 19727, r.ticks[1]                       # 2024-01-05
    end
    assert_equal [true, false], t.stddev(axis: 1).mask.to_a
  end

  # -- 8. the unit: keyword is gone ----------------------------------------

  def test_mean_no_longer_takes_a_unit_keyword
    t = days
    assert_raise(ArgumentError) { t.mean(unit: :ns) }
    assert_raise(ArgumentError) { t.median(unit: :s) }
    assert_raise(ArgumentError) { t.stddev(unit: :ns) }
  end

  def test_precision_is_declared_with_to_unit_instead
    t = CArray.time(%w[2024-06-15 2024-06-16], unit: :D)
    fine = t.to_unit(:h).mean
    assert_equal :h, fine.unit.base
    assert_equal Time.utc(2024, 6, 15, 12), fine.to_time
  end

  def test_to_unit_buys_back_the_precision_a_coarse_spread_loses
    # The accepted price of the rule (§5): a spread is not a lattice point, so
    # on :D it rounds hard.  Declaring a finer grid first recovers it.
    t = CArray.time(%w[2024-01-01 2024-01-02 2024-01-05 2024-01-09], unit: :D)
    exact = t.ticks.stddev                                  # 3.5939... days
    assert_equal 4, t.stddev.value                          # ~11% off
    assert_equal 86, t.to_unit(:h).stddev.value             # 86.25 h -> 86
    assert_in_delta exact * 24, t.to_unit(:h).stddev.value, 0.5
  end

  # -- 9. the plain surface is untouched -----------------------------------

  def test_plain_numeric_reductions_are_unchanged
    plain = days.ticks.copy
    assert_instance_of Float, plain.mean
    assert_instance_of Float, plain.median
    assert_equal plain.mean.round,          days.mean.value
    assert_equal plain.median.round,        days.median.value
    assert_equal plain.percentile(50).round, days.percentile(50).value
    assert_equal plain.stddev.round,        days.stddev.value
  end

end


# CATimedelta is a NonNumeric Face (CA_FIXLEN surface over int64 storage),
# like CATime.  Before that, the numeric kernels dispatched on it: sqrt / exp
# / log / sin of a duration returned bare numbers, variance returned squared
# ticks, and abs dropped the Face.  The operations that *are* meaningful on a
# duration are Ruby overrides, so they are unaffected.
class TestTimedeltaNumericGate < Test::Unit::TestCase
  def durations
    CArray.time([5, 20], unit: :s) - CArray.time([0, 10], unit: :s)   # 5s, 10s
  end

  def test_the_surface_is_gated_and_the_storage_is_the_parent
    td = durations
    assert_equal :fixlen, td.data_type
    assert_equal :int64, td.parent.data_type
    assert_equal [5, 10], td.ticks.to_a
  end

  def test_math_on_a_duration_refuses
    td = durations
    [:sqrt, :exp, :log, :sin].each do |m|
      assert_raise(CArray::DataTypeError, "#{m} of a duration should refuse") { td.send(m) }
    end
  end

  def test_abs_and_negation_keep_the_face
    td = CArray.time([0, 10], unit: :s) - CArray.time([5, 20], unit: :s)   # -5s, -10s
    assert_kind_of CATimedelta, td.abs
    assert_equal [5, 10], td.abs.ticks.to_a
    assert_kind_of CATimedelta, -td
    assert_equal [5, 10], (-td).ticks.to_a
    assert_equal td.unit.to_s, td.abs.unit.to_s
  end

  def test_the_meaningful_reductions_are_untouched
    td = durations
    assert_kind_of CATimedelta::Element, td.sum
    assert_kind_of CATimedelta::Element, td.mean
    assert_kind_of CATimedelta::Element, td.median
    assert_kind_of CATimedelta::Element, td.min
    assert_kind_of CATimedelta::Element, td.stddev
    assert_kind_of CATimedelta, (td + td)
    assert_kind_of CATimedelta, (td * 2)
  end

  def test_a_number_is_asked_for_by_name_not_by_cast
    # No #to_numeric: a duration is a count *of a unit*, and a bare float
    # would drop the unit silently. #ticks says which count it is, and
    # #to_unit picks the grid first.
    td = durations
    e = assert_raise(TypeError) { td.to_type(:float64) }
    assert_match(/to_numeric/, e.message)
    assert_equal [5, 10], td.ticks.to_a
    assert_equal [5000, 10000], td.to_unit(:ms).ticks.to_a
  end

  def test_the_surface_still_reads_as_elements
    td = durations
    assert_kind_of CATimedelta::Element, td[0]
    assert_kind_of CATimedelta::Element, td.to_a[0]
    assert_kind_of CATimedelta::Element, td.to_type(:object)[0]
  end
end

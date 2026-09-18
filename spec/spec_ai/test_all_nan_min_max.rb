require_relative "../../lib/carray"
require "test/unit"

# An extreme-value reduction that meets only NaN used to answer with its
# own starting value -- min gave +Infinity, max gave -Infinity, minmax
# gave the impossible interval [+Infinity, -Infinity], and min_index gave
# 0, which claims the minimum sits at a cell holding NaN.
#
# A NaN is skipped rather than propagated by these kernels because the
# compare that drives them (`v < acc`) is false for NaN.  That makes them
# a fold of C99 fmin / fmax, whose documented rule is already what the
# element-wise twins (pmin / elem_min / scatter_min) and the CA_OBJECT
# lane follow: a lone number beats NaN, two NaNs give NaN.  The float
# lanes now answer the same way.
#
# Positions are the exception.  An integer output cannot hold NaN, so the
# argmin family answers UNDEF -- the same answer an all-masked fiber
# gets, and the only one that does not name a cell.
#
# Masks are untouched by all of this: a mask marks a cell as not taken,
# and empty / all-masked still answer UNDEF.
class TestAllNaNMinMax < Test::Unit::TestCase

  NAN = 0.0 / 0.0
  INF = Float::INFINITY

  def all_nan(n = 3, data_type = :float64)
    CArray.send(data_type, n) { NAN }
  end

  def all_masked(n = 3)
    ca = CArray.float64(n) { 1.0 }
    ca.mask = 1
    ca
  end

  # ---- the answer is NaN -------------------------------------------------

  def test_all_nan_min_max_is_nan
    [:float64, :float32].each do |dt|
      assert(all_nan(3, dt).min.nan?, "#{dt} min")
      assert(all_nan(3, dt).max.nan?, "#{dt} max")
    end
  end

  def test_all_nan_minmax_is_nan_pair
    lo, hi = all_nan.minmax
    assert(lo.nan?)
    assert(hi.nan?)
  end

  def test_all_nan_cumulative_is_nan
    assert(CA_DOUBLE([NAN, NAN]).cummin.to_a.all?(&:nan?))
    assert(CA_DOUBLE([NAN, NAN]).cummax.to_a.all?(&:nan?))
  end

  # The running form answers per position: the prefix that has seen only
  # NaN is NaN, and from the first number on it is that running extreme.
  def test_cumulative_prefix_adopts_first_number
    got = CA_DOUBLE([NAN, 1.0, NAN, 0.5]).cummin.to_a
    assert(got[0].nan?)
    assert_equal [1.0, 1.0, 0.5], got[1..-1]
    got = CA_DOUBLE([NAN, 1.0, NAN, 2.0]).cummax.to_a
    assert(got[0].nan?)
    assert_equal [1.0, 1.0, 2.0], got[1..-1]
  end

  # ---- the answer is UNDEF (positions) ----------------------------------

  def test_all_nan_position_is_undef
    %i[min_index max_index min_addr max_addr].each do |m|
      assert_equal UNDEF, all_nan.send(m), m.to_s
    end
  end

  def test_all_nan_position_matches_all_masked
    %i[min_index max_index min_addr max_addr].each do |m|
      assert_equal all_masked.send(m), all_nan.send(m), m.to_s
    end
  end

  # ---- the float lane and the object lane agree -------------------------

  # CA_OBJECT reduces through Ruby's <=> from a sentinel that adopts the
  # first cell, so its answer for an all-NaN array was already NaN while
  # the float lane said Infinity.  The same array must not answer
  # differently for being held as objects.
  def test_object_lane_agrees_with_float_lane
    obj = CA_OBJECT([NAN, NAN])
    flt = CA_DOUBLE([NAN, NAN])
    assert_equal flt.min.nan?, obj.min.nan?
    assert_equal flt.max.nan?, obj.max.nan?
    assert_equal flt.cummin.to_a.map(&:nan?), obj.cummin.to_a.map(&:nan?)
  end

  # ---- a real infinity is still an answer -------------------------------

  # Data that genuinely holds only +Infinity reaches the same accumulator
  # value as data that held only NaN.  They must not collapse together.
  def test_real_infinity_is_not_mistaken_for_all_nan
    assert_equal INF,  CA_DOUBLE([INF, INF]).min
    assert_equal INF,  CA_DOUBLE([INF, INF]).max
    assert_equal(-INF, CA_DOUBLE([-INF, -INF]).min)
    assert_equal(-INF, CA_DOUBLE([-INF, -INF]).max)
    assert_equal [INF, INF], CA_DOUBLE([INF, INF]).minmax
    assert_equal 0, CA_DOUBLE([INF, INF]).min_index
    assert_equal [INF, 1.0], CA_DOUBLE([INF, 1.0]).cummin.to_a
  end

  # ---- one number is enough ---------------------------------------------

  def test_a_single_number_still_wins
    a = CA_DOUBLE([1.0, NAN, 3.0])
    assert_equal 1.0, a.min
    assert_equal 3.0, a.max
    assert_equal [1.0, 3.0], a.minmax
    assert_equal 0, a.min_index
    assert_equal 2, a.max_index
    assert_equal [1.0, 1.0, 1.0], a.cummin.to_a
  end

  # ---- nothing to reduce is still UNDEF ---------------------------------

  def test_empty_and_all_masked_are_unchanged
    assert_equal UNDEF, CArray.float64(0).min
    assert_equal UNDEF, CArray.float64(0).max
    assert_equal UNDEF, all_masked.min
    assert_equal UNDEF, all_masked.max
    assert_equal UNDEF, all_masked.minmax
    assert_equal [UNDEF, UNDEF, UNDEF], all_masked.cummin.to_a
  end

  # A cell can be both masked and NaN-valued; the mask decides.
  def test_masked_and_nan_mixed
    a = CA_DOUBLE([NAN, 1.0, NAN])
    a[1] = UNDEF
    assert(a.min.nan?)
    assert_equal UNDEF, a.min_index
  end

  # ---- integers and booleans have no NaN --------------------------------

  def test_integer_and_boolean_are_untouched
    assert_equal 1, CA_INT([3, 1, 2]).min
    assert_equal 3, CA_INT([3, 1, 2]).max
    assert_equal 1, CA_INT([3, 1, 2]).min_index
    assert_equal [3, 1, 1], CA_INT([3, 1, 2]).cummin.to_a
    assert_equal [1, 3], CA_INT([3, 1, 2]).minmax
    assert_equal 0, CA_BOOLEAN([1, 0, 1]).min
  end

  # ---- per axis ----------------------------------------------------------

  # Row 0 holds only NaN, row 1 is all masked, row 2 is ordinary.  The
  # three answers are NaN, UNDEF and the real minimum -- one fiber's
  # emptiness does not spill into its neighbours.
  def test_per_axis_answers_each_fiber_on_its_own
    a = CArray.float64(3, 3) { |i, j| i == 0 ? NAN : (i * 3 + j).to_f }
    a[1, nil] = UNDEF
    got = a.min(axis: 1).to_a
    assert(got[0].nan?)
    assert_equal UNDEF, got[1]
    assert_equal 6.0, got[2]
    idx = a.min_index(axis: 1).to_a
    assert_equal UNDEF, idx[0]
    assert_equal UNDEF, idx[1]
    assert_equal 0, idx[2]
  end

  # ---- the same answer whichever path the data arrives by -----------------

  # min / max have five emit paths (generic slab walk, three tiled
  # loop-interchange variants for contiguous and stacked sources, and a
  # chunked walk for lazy views).  Each carried its own copy of the
  # starting value, so each had to be told about NaN separately.  The
  # shapes below are chosen to reach them.
  def test_every_path_gives_the_same_answer
    # tiled: contiguous source, reduction over a non-innermost axis
    tiled = CArray.float64(64, 128) { NAN }
    assert(tiled.min(axis: 0).to_a.all?(&:nan?), "tiled min")
    assert(tiled.max(axis: 0).to_a.all?(&:nan?), "tiled max")

    # tiled, stacked source, over each of the two axis positions
    stacked = CArray.stack([CArray.float64(64, 128) { NAN },
                            CArray.float64(64, 128) { NAN }], axis: 0)
    assert(stacked.min(axis: 1).to_a.flatten.all?(&:nan?), "stacked axis 1")
    assert(stacked.min(axis: 2).to_a.flatten.all?(&:nan?), "stacked axis 2")

    # chunked walk over a lazy view
    lazy = CArray.float64(100_000) { NAN }.lazy + 0.0
    assert(lazy.min.nan?, "lazy min")
    assert((CArray.float64(100_000) { NAN }.lazy + 0.0).max.nan?, "lazy max")
  end

  # The tiled path decides per output cell, so a single all-NaN column
  # must not disturb the columns beside it.
  def test_tiled_path_isolates_the_all_nan_column
    a = CArray.float64(64, 128) { |i, j| j.zero? ? NAN : (i + j).to_f }
    got = a.min(axis: 0).to_a
    assert(got[0].nan?)
    assert_equal (1..127).map(&:to_f), got[1..-1]
  end

  # The same paths must keep answering Infinity for data that holds it.
  def test_every_path_keeps_a_real_infinity
    assert_equal [INF] * 128,
                 CArray.float64(64, 128) { INF }.min(axis: 0).to_a
    assert_equal INF, (CArray.float64(100_000) { INF }.lazy + 0.0).min
  end

  # ---- the element-wise twins were already right ------------------------

  def test_element_wise_twins_are_unchanged
    x = CA_DOUBLE([NAN, NAN])
    assert(x.pmin(CA_DOUBLE([NAN, NAN])).to_a.all?(&:nan?))
    assert(x.pmax(CA_DOUBLE([NAN, NAN])).to_a.all?(&:nan?))
    assert_equal [1.0, 2.0], x.pmin(CA_DOUBLE([1.0, 2.0])).to_a
  end
end

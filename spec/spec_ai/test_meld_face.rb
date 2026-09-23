require "test/unit"
require "carray"

# meld was the one multi-parent constructor that neither asked whether a Face
# could be carried across parents nor lifted one that could.  It returned the
# raw storage of whatever it was given -- for CAConstString the 16-byte
# (start,end) pairs presented as the string cells, for CATime the raw int64
# ticks.  Both looked like data.  It follows the rule CAStack already applied.
class TestMeldFace < Test::Unit::TestCase

  def time (*days)
    CArray.time(days, unit: :D)
  end

  # ---- a Face whose state is per-parent is refused --------------------

  def test_meld_refuses_a_const_string
    a = CArray.const_string(%w[alpha beta])
    b = CArray.const_string(%w[gamma])
    err = assert_raise(ArgumentError) { CArray.meld(a, b) }
    assert_match(/CAConstString/, err.message)
    assert_match(/not portable/, err.message)
  end

  def test_meld_refuses_a_string_face_as_stack_does
    a = CArray.string(%w[p q])
    b = CArray.string(%w[r s])
    assert_raise(ArgumentError) { CArray.meld(a, b) }
    assert_raise(ArgumentError) { CArray.stack([a, b]) }
  end

  def test_the_refusal_names_the_way_out
    a = CArray.const_string(%w[alpha beta])
    err = assert_raise(ArgumentError) { CArray.meld(a, CArray.const_string(%w[g])) }
    assert_match(/\.parent/, err.message)
    # and the way out works
    welded = CArray.meld(a.parent, CArray.const_string(%w[g]).parent)
    assert_equal 3, welded.elements
  end

  def test_caframe_meld_is_covered_by_the_same_check
    df1 = CAFrame.new("name" => CArray.const_string(%w[alpha beta]))
    df2 = CAFrame.new("name" => CArray.const_string(%w[gamma]))
    assert_raise(ArgumentError) { CAFrame.meld(df1, df2) }
  end

  # ---- a Face that can be carried is lifted ---------------------------

  def test_meld_lifts_a_fixlen_string
    r = CArray.meld(CArray.fixlen_string(%w[p q], bytes: 2),
                    CArray.fixlen_string(%w[r s], bytes: 2))
    assert_equal CAFixlenString, r.class
    assert_equal %w[p q r s], r.to_a
  end

  def test_meld_lifts_a_time
    r = CArray.meld(time("2026-01-01", "2026-01-02"), time("2026-01-03"))
    assert_equal CATime, r.class
    assert_equal %w[2026-01-01 2026-01-02 2026-01-03], r.to_a.map(&:to_s)
  end

  def test_meld_lifts_a_timedelta
    d = time("2026-01-01", "2026-01-05") - time("2026-01-01", "2026-01-01")
    r = CArray.meld(d, d)
    assert_equal CATimedelta, r.class
    assert_equal [0, 4, 0, 4], r.to_a.map { |e| e.to_s.to_i }
  end

  def test_meld_refuses_faces_whose_state_differs
    err = assert_raise(ArgumentError) do
      CArray.meld(time("2026-01-01"), CArray.time(%w[2026-01-02], unit: :h))
    end
    assert_match(/state mismatch/, err.message)
  end

  # ---- everything else is untouched -----------------------------------

  def test_plain_arrays_are_unaffected
    r = CArray.meld(CArray.int32(2) { |i| i }, CArray.int32(2) { |i| i + 2 })
    assert_equal CAMeld, r.class
    assert_equal [0, 1, 2, 3], r.to_a
  end

  def test_ragged_and_writeback_still_work
    a = CArray.float64(2) { |i| i * 1.5 }
    b = CArray.float64(1) { 9.0 }
    r = CArray.meld(a, b)
    assert_equal [0.0, 1.5, 9.0], r.to_a
    r[0] = 7.0
    assert_equal 7.0, a[0]
  end

  # A lone parent has nothing to weld against, so there is no portability
  # question and none is asked -- the same place CAStack stops.
  def test_a_single_parent_is_not_refused
    assert_nothing_raised { CArray.meld(CArray.const_string(%w[a b])) }
    assert_nothing_raised { CArray.stack([CArray.const_string(%w[a b])]) }
  end

end

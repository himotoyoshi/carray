require "test/unit"
require "carray"

# A frozen frame refuses the edits made through its own methods; its
# columns' cells stay their arrays' own, as an Array's elements do.
class TestCAFrameFrozen < Test::Unit::TestCase

  def frozen_frame
    CAFrame.new({ "a" => CArray.int32(3).seq, "s" => CArray.object(3) { "2024-01-01" } }).freeze
  end

  def test_assignment_is_refused
    d = frozen_frame
    assert_raise(FrozenError) { d["c"] = CArray.int32(3) }
    assert_raise(FrozenError) { d["a"] = nil }
    assert_raise(FrozenError) { d["a"] = UNDEF }
    assert_raise(FrozenError) { d[0] = UNDEF }
    assert_raise(FrozenError) { d[0] = nil }
    assert_equal ["a", "s"], d.variable_names
    assert_equal [0, 1, 2], d["a"].to_a
  end

  def test_in_place_verbs_are_refused
    d = frozen_frame
    assert_raise(FrozenError) { d.set_index("a") }
    assert_raise(FrozenError) { d.reset_index }
    assert_raise(FrozenError) { d.cast("a" => :float64) }
    assert_raise(FrozenError) { d.promote }
    assert_raise(FrozenError) { d.parse_to_time("s") }
    assert_raise(FrozenError) { d.fill("a", 0) }
    assert_raise(FrozenError) { d.mask_eq("a", 1) }
    assert_equal :int32, d["a"].data_type
    assert_equal false, d["a"].has_mask?
  end

  def test_verbs_that_return_a_new_frame_still_work
    d = frozen_frame
    assert_equal ["a", "s", "c"], d.append("c", CArray.int32(3)).variable_names
    x = d.dup
    x["c"] = CArray.int32(3)
    assert_equal ["a", "s", "c"], x.variable_names
  end

end

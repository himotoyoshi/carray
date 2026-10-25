# frozen_string_literal: true

require "test/unit"
require "carray"

# A verb computed within each group refuses the group key, as a reduction
# does: the key is one value in a group, and a fill would write to what the
# groups were made from.
class TestCAFrameGroupKeyOnRows < Test::Unit::TestCase
  def setup
    k = CA_INT32([1, 1, 2, 2])
    k[1] = UNDEF
    @df = CAFrame.new("k" => k, "v" => CA_FLOAT64([1, 2, 3, 4]))
    @g = @df.group_by("k")
  end

  def test_row_shaped_verbs_refuse_the_key
    [-> { @g.cumsum("k") }, -> { @g.cumcount("k") }, -> { @g.order("k") },
     -> { @g.lag("k") }, -> { @g.cumsum("v", "k") }].each do |call|
      e = assert_raise(ArgumentError) { call.call }
      assert_match(/"k" is the group key/, e.message)
    end
  end

  def test_fill_leaves_the_key_alone
    assert_raise(ArgumentError) { @g.fill("k", 9) }
    assert_raise(ArgumentError) { @g.fill("k" => 9) }
    assert_equal [true, false, true, true], @df["k"].is_not_masked.to_a
  end

  def test_the_other_columns
    assert_equal [1.0, UNDEF, 3.0, 7.0], @g.cumsum("v").to_a
    assert_equal ["v"], @g.cumsum.column_names
  end
end

require "test/unit"
require "carray"

# GroupedFrame#filter keeps the rows of the groups its block chooses, one
# boolean per group, and leaves the rest of the selection to CAFrame#filter:
# the result is a sub-frame sharing the frame's columns, and an undetermined
# row is dropped or, with keep_masked:, carried masked.

class TestCAFrameGroupFilter < Test::Unit::TestCase

  def frame
    station = CA_OBJECT(%w[tokyo osaka tokyo nagoya tokyo osaka])
    station[5] = UNDEF                  # a row in no group
    temp = CA_FLOAT64([10, 20, 11, 30, 13, 25])
    temp[2] = UNDEF
    CAFrame.new("station" => station, "temp" => temp)
  end

  def test_keeps_the_chosen_groups
    grp = frame.group_by("station")             # tokyo, osaka, nagoya
    kept = grp.filter { |g| g["temp"].count_not_masked >= 2 }
    assert_equal %w[tokyo tokyo tokyo], kept["station"].to_a
    kept = grp.filter { |g| g.mean("temp") > 15.0 }
    assert_equal %w[osaka nagoya], kept["station"].to_a
    assert_equal [20.0, 30.0], kept["temp"].to_a
  end

  # The rows keep the frame's order, not the order of the groups.
  def test_frame_order
    df = CAFrame.new("k" => CA_OBJECT(%w[b a b a]), "v" => CA_INT32([1, 2, 3, 4]))
    assert_equal [1, 2, 3, 4], df.group_by("k").filter { |g| CA_BOOLEAN([true, true]) }["v"].to_a
  end

  def test_undetermined_rows
    grp = frame.group_by("station")
    chosen = CA_BOOLEAN([true, false, true])
    chosen[2] = UNDEF                           # nagoya undetermined
    assert_equal %w[tokyo tokyo tokyo], grp.filter { chosen }["station"].to_a
    carried = grp.filter(keep_masked: true) { chosen }
    # tokyo, tokyo (masked already), nagoya, tokyo, the row in no group
    assert_equal [10.0, UNDEF, UNDEF, 13.0, UNDEF], carried["temp"].to_a
  end

  def test_a_view_of_the_frame
    df = frame
    kept = df.group_by("station").filter { |g| g.mean("temp") > 15.0 }
    kept["temp"][0] = 99.0
    assert_equal 99.0, df["temp"][1]
  end

  def test_block_must_give_one_boolean_per_group
    grp = frame.group_by("station")
    assert_raise(ArgumentError) { grp.filter { CA_INT32([1, 0, 1]) } }
    assert_raise(ArgumentError) { grp.filter { CA_BOOLEAN([true]) } }
    assert_raise(ArgumentError) { grp.filter { [true, false, true] } }
  end

  def test_resample_bins
    t  = CArray.time_range("2024-01-01T00:00", "2024-01-01T05:00", unit: :h)
    v  = CA_FLOAT64([1, 2, 3, 4, 5, 6])
    v[4] = UNDEF
    df = CAFrame.new("time" => t, "v" => v).set_index("time")
    kept = df.resample("time", "3 hours").filter { |g| g["v"].count_not_masked >= 3 }
    assert_equal [1.0, 2.0, 3.0], kept["v"].to_a
    assert_equal t[0..2].to_a.map(&:to_s), kept.index.to_a.map(&:to_s)
  end
end

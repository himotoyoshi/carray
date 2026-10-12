require "test/unit"
require "carray"

# CAFrame.stack puts frames of the same shape on top of each other as layers:
# each column gains an axis over the frames, the rows stay.  unstack is the
# inverse.
class TestCAFrameStackUnstack < Test::Unit::TestCase
  def frame(k)
    CAFrame.new({ "temp" => CA_FLOAT64([10, 20, 30]) + k,
                  "rh"   => CA_INT32([50, 60, 70]) + k,
                  "t"    => CArray.time(["2024-01-01", "2024-01-02", "2024-01-03"]),
                  "v"    => CA_FLOAT64([[1, 2], [3, 4], [5, 6]]) + k },
                index: CA_OBJECT(%w[tokyo osaka sapporo]), axis_name: "station")
  end

  def setup
    @frames = (0..2).map { |k| frame(k) }
    @s = CAFrame.stack(*@frames)
  end

  def test_each_column_gains_a_layer_axis_after_the_rows
    assert_equal 3, @s.nrow
    assert_equal [[3, 3], [3, 3], [3, 3], [3, 3, 2]], @s.columns.map(&:shape)
    assert_equal %w[tokyo osaka sapporo], @s.index.to_a
    assert_equal "station", @s.axis_name
    assert_equal [11.0, 21.0, 31.0], @s["temp"][nil, 1].to_a
    assert_equal [[2.0, 3.0], [4.0, 5.0], [6.0, 7.0]], @s["v"][nil, 1, nil].to_a
    assert_kind_of CATime, @s["t"]
    assert_equal [11.0, 21.0, 31.0], @s["temp"].mean(axis: 1).to_a
  end

  def test_the_stack_is_a_view_of_the_frames
    @s["temp"][0, 2] = 99
    assert_equal 99.0, @frames[2]["temp"][0]
  end

  def test_row_verbs_work_on_the_stack
    assert_equal %w[osaka sapporo], @s.filter { |f| f["temp"][nil, 0] > 15 }.index.to_a
    assert_equal 6, CAFrame.meld(@s, @s).nrow
  end

  def test_unstack_is_the_inverse
    parts = @s.unstack(axis: 1)
    assert_equal 3, parts.size
    parts.each_with_index do |part, k|
      assert_equal @frames[k].column_names, part.column_names
      part.column_names.each { |n| assert_equal @frames[k][n].to_a, part[n].to_a }
      assert_equal @frames[k].index.to_a, part.index.to_a
    end
    back = CAFrame.stack(*parts)
    back.column_names.each { |n| assert_equal @s[n].to_a, back[n].to_a }
  end

  def test_unstack_pieces_are_views
    @s.unstack(axis: 1)[0]["rh"][1] = -1
    assert_equal(-1, @frames[0]["rh"][1])
  end

  def test_masks_and_empty_frames_carry_through
    a = CAFrame.new("x" => CA_INT32([1, 2]))
    a["x"][1] = UNDEF
    assert_equal [[1, 1], [UNDEF, UNDEF]], CAFrame.stack(a, a)["x"].to_a
    e = @frames[0][CA_BOOLEAN([0, 0, 0])]
    assert_equal [0, 2], CAFrame.stack(e, e)["temp"].shape
  end

  def test_the_frames_have_to_be_the_same_shape
    assert_raise(ArgumentError) { CAFrame.stack(@frames[0], @frames[1].drop("rh")) }
    assert_raise(ArgumentError) { CAFrame.stack(@frames[0], @frames[1][0..1]) }
    other = CAFrame.new(@frames[1].column_names.to_h { |n| [n, @frames[1][n]] },
                        index: CA_OBJECT(%w[a b c]), axis_name: "station")
    assert_raise(ArgumentError) { CAFrame.stack(@frames[0], other) }
  end

  def test_the_layer_axis_counts_from_one
    assert_raise(ArgumentError) { CAFrame.stack(*@frames, axis: 0) }
    assert_raise(ArgumentError) { CAFrame.stack(*@frames, axis: -1) }
    assert_raise(ArgumentError) { CAFrame.stack(*@frames, axis: 2) }   # temp is 1-D
    assert_raise(TypeError)     { CAFrame.stack(*@frames, axis: 1.0) }
    assert_raise(ArgumentError) { @s.unstack(axis: 0) }
  end

  def test_unstack_needs_the_axis_in_every_column
    assert_raise(ArgumentError) { @frames[0].unstack(axis: 1) }   # temp has no axis 1
    assert_raise(ArgumentError) { @s.unstack(axis: 2) }          # only v has it
  end

  def test_group_by_refuses_a_key_with_more_than_one_value_per_row
    err = assert_raise(ArgumentError) { @s.group_by("rh") }
    assert_match(/not one value per row/, err.message)
    g = @s.group_by(@s["rh"][nil, 0] > 55)
    assert_equal 2, g.ngroup
  end
end

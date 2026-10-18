require "test/unit"
require "carray"

# An index made from a key column -- group_by's single key, resample's
# bins, pivot's sorted keys -- shows the key as the column does: its data
# type, Face, unit and attributes, by one part.  resample had made its
# bins with floor / ceil / time_range, which carry no attributes, so the
# index of a time column with attributes had none.
class TestCAFrameKeyLabels < Test::Unit::TestCase

  def setup
    @t = CArray.time(["2024-01-01 00:10", "2024-01-01 00:50", "2024-01-01 02:20"], unit: :m)
    @t.set_attrs("tz" => "UTC")
    @k = CA_INT32([1, 2, 1])
    @k.set_attrs("units" => "station")
    @df = CAFrame.new("t" => @t, "k" => @k, "v" => CA_FLOAT64([1, 2, 3]))
  end

  def assert_time_labels (index, message)
    assert_kind_of CATime, index, message
    assert_equal @t.unit, index.unit, message
    assert_equal({ "tz" => "UTC" }, index.attrs, message)
  end

  def test_every_resample_index_shows_the_time_column
    assert_time_labels @df.resample("t", :h).mean.index, "left"
    assert_time_labels @df.resample("t", :h, label: :right).mean.index, "right"
    assert_time_labels @df.resample("t", :h, fill: true).mean.index, "fill"
    assert_time_labels @df.resample("t", :M, fill: true).mean.index, "calendar fill"
    assert_time_labels @df.resample("t", "1 hour", origin: "2024-01-01 00:30").mean.index, "origin"
    on_index = CAFrame.new({ "v" => CA_FLOAT64([1, 2, 3]) }, axis_name: "t", index: @t)
    assert_time_labels on_index.resample("t", :h).mean.index, "by the index"
  end

  # align and windows(at:) take the caller's array as the keys: a copy,
  # shown with the key's attributes, the caller's array left as it was.
  def test_align_and_windows_at_show_the_key
    ref = CA_INT32([2, 1, 5])
    a = @df.align("k", ref)
    assert_equal({ "units" => "station" }, a["k"].attrs)
    assert_not_same ref, a["k"]
    ref[0] = 9
    assert_equal [2, 1, 5], a["k"].to_a
    on_index = CAFrame.new({ "v" => CA_FLOAT64([1, 2, 3]) }, axis_name: "k", index: @k)
    assert_equal({ "units" => "station" }, on_index.align("k", ref).index.attrs)
    assert_equal({}, ref.attrs)
    at = CArray.time(["2024-01-01 01:00"], unit: :m)
    assert_time_labels @df.windows(on: "t", at: at, before: "1 hour").mean.index, "windows at"
    assert_equal({}, at.attrs)
  end

  def test_group_by_and_pivot_show_the_key
    assert_time_labels @df.group_by("t").mean.index, "group_by"
    assert_equal({ "units" => "station" }, @df.group_by("k").mean.index.attrs)
    wide = @df.pivot(index: "k", columns: "t", values: "v")
    assert_equal :int32, wide.index.data_type
    assert_equal({ "units" => "station" }, wide.index.attrs)
    _, rows, cols = @df.pivot_grid(index: "k", columns: "t", values: "v")
    assert_equal({ "units" => "station" }, rows.attrs)
    assert_time_labels cols, "pivot_grid columns"
  end
end

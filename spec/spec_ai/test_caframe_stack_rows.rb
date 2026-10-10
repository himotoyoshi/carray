require "test/unit"
require "carray"

# stack_rows makes each group's rows one row, every other column an N-D column
# over them; unstack_rows spreads them back.
class TestCAFrameStackRows < Test::Unit::TestCase
  def setup
    @long = CAFrame.new("station" => CA_OBJECT(%w[tokyo tokyo tokyo osaka osaka osaka]),
                        "level"   => CA_INT32([1000, 850, 500, 1000, 850, 500]),
                        "temp"    => CA_FLOAT64([15, 5, -20, 17, 7, -18]),
                        "time"    => CArray.time(%w[2024-01-01 2024-01-01 2024-01-01
                                                    2024-01-02 2024-01-02 2024-01-02]),
                        "wind"    => CA_FLOAT64([[1, 2], [3, 4], [5, 6], [7, 8], [9, 10], [11, 12]]))
    @long["temp"][4] = UNDEF
  end

  def test_each_group_becomes_one_row
    n = @long.stack_rows(by: "station")
    assert_equal 2, n.nrow
    assert_equal "station", n.axis_name
    assert_equal %w[tokyo osaka], n.index.to_a
    assert_equal %w[level temp time wind], n.column_names
    assert_equal [[1000, 850, 500], [1000, 850, 500]], n["level"].to_a
    assert_equal [[15.0, 5.0, -20.0], [17.0, UNDEF, -18.0]], n["temp"].to_a
    assert_equal [2, 3, 2], n["wind"].shape
    assert_kind_of CATime, n["time"]
    assert_equal [-20.0, -18.0], n["temp"].min(axis: 1).to_a
  end

  def test_rows_are_stacked_in_frame_order
    shuffled = @long[CA_INT64([3, 0, 4, 1, 5, 2])]
    n = shuffled.stack_rows(by: "station")
    assert_equal %w[osaka tokyo], n.index.to_a
    assert_equal [[1000, 850, 500], [1000, 850, 500]], n["level"].to_a
  end

  def test_unstack_rows_is_the_inverse
    back = @long.stack_rows(by: "station").unstack_rows
    assert_equal 6, back.nrow
    assert_equal @long["station"].to_a, back.index.to_a
    back.reset_index
    @long.column_names.each { |c| assert_equal @long[c].to_a, back[c].to_a, c }
  end

  def test_the_stack_is_a_view
    n = @long.stack_rows(by: "station")
    n["temp"][1, 0] = 99.0
    assert_equal 99.0, @long["temp"][3]
  end

  def test_the_frames_own_index_is_stacked_as_a_column
    x = CAFrame.new({ "st" => CA_OBJECT(%w[a a b b]), "v" => CA_INT32([1, 2, 3, 4]) },
                    index: CA_INT32([10, 20, 30, 40]), axis_name: "id")
    n = x.stack_rows(by: "st")
    assert_equal %w[id v], n.column_names
    assert_equal [[10, 20], [30, 40]], n["id"].to_a
    y = CAFrame.new({ "v" => CA_INT32([1, 2, 3, 4]) }, index: CA_OBJECT(%w[a a b b]), axis_name: "st")
    assert_equal [[1, 2], [3, 4]], y.stack_rows(by: "st")["v"].to_a
  end

  def test_groups_have_to_be_the_same_size_and_every_row_keyed
    err = assert_raise(ArgumentError) { @long[0..4].stack_rows(by: "station") }
    assert_match(/same number in every group/, err.message)
    masked = @long.copy
    masked["station"][5] = UNDEF
    assert_raise(ArgumentError) { masked.stack_rows(by: "station") }
    assert_raise(ArgumentError) { @long.stack_rows(by: []) }
  end

  def test_an_empty_frame
    n = @long[CA_BOOLEAN([0] * 6)].stack_rows(by: "station")
    assert_equal 0, n.nrow
    assert_equal [0, 0], n["temp"].shape
    assert_equal 0, n.unstack_rows.nrow
  end

  def test_unstack_rows_needs_n_d_columns_of_one_length
    flat = CAFrame.new("v" => CA_INT32([1, 2]))
    assert_raise(ArgumentError) { flat.unstack_rows }
    mixed = CAFrame.new("a" => CA_INT32([[1, 2], [3, 4]]), "b" => CA_INT32([[1, 2, 3], [4, 5, 6]]))
    assert_raise(ArgumentError) { mixed.unstack_rows }
  end

  # on: lines the rows up by a column's values; a group without a row for a
  # value has UNDEF there, as pivot leaves a missing cell.
  def test_on_lines_rows_up_and_masks_the_missing_ones
    long = CAFrame.new("station" => CA_OBJECT(%w[tokyo tokyo tokyo osaka osaka]),
                       "level"   => CA_INT32([1000, 850, 500, 1000, 500]),
                       "temp"    => CA_FLOAT64([15, 5, -20, 17, -18]),
                       "label"   => CArray.const_string(%w[a b c d e]),
                       "wind"    => CA_FLOAT64([[1, 2], [3, 4], [5, 6], [7, 8], [9, 10]]))
    n = long.stack_rows(by: "station", on: "level")
    assert_equal %w[tokyo osaka], n.index.to_a
    assert_equal [[1000, 850, 500], [1000, 850, 500]], n["level"].to_a
    assert_equal [[15.0, 5.0, -20.0], [17.0, UNDEF, -18.0]], n["temp"].to_a
    assert_equal [%w[a b c], ["d", UNDEF, "e"]], n["label"].to_a
    assert_equal [[7.0, 8.0], [UNDEF, UNDEF], [9.0, 10.0]], n["wind"][1, nil, nil].to_a
    # a new frame: the missing cells are new
    n["temp"][0, 0] = 99.0
    assert_equal 15.0, long["temp"][0]
  end

  def test_on_takes_the_values_in_order_of_first_appearance
    long = CAFrame.new("st" => CA_OBJECT(%w[b b a a a]),
                       "lv" => CA_INT32([500, 1000, 1000, 850, 500]),
                       "v"  => CA_INT32([1, 2, 3, 4, 5]))
    n = long.stack_rows(by: "st", on: "lv")
    assert_equal [500, 1000, 850], n["lv"].to_a[0]
    assert_equal [[1, 2, UNDEF], [5, 3, 4]], n["v"].to_a
  end

  def test_on_refuses_two_rows_for_one_place
    long = CAFrame.new("st" => CA_OBJECT(%w[a a]), "lv" => CA_INT32([1, 1]), "v" => CA_INT32([1, 2]))
    err = assert_raise(ArgumentError) { long.stack_rows(by: "st", on: "lv") }
    assert_match(/more than one row for "a", lv=1/, err.message)
    masked = CAFrame.new("st" => CA_OBJECT(%w[a a]), "lv" => CA_INT32([1, 2]), "v" => CA_INT32([1, 2]))
    masked["lv"][1] = UNDEF
    assert_raise(ArgumentError) { masked.stack_rows(by: "st", on: "lv") }
    assert_raise(ArgumentError) { masked.stack_rows(by: "st", on: "st") }
    empty = masked[CA_BOOLEAN([0, 0])].stack_rows(by: "st", on: "lv")
    assert_equal [0, 0], empty["v"].shape
  end

  # by: takes a CArray key as group_by does: an hourly series becomes one row
  # per day.  It used to be split into its elements.
  def test_a_computed_key_folds_consecutive_rows
    h = CAFrame.new("time" => CArray.time_series("2024-01-01", count: 48, unit: :h),
                    "v"    => CA_FLOAT64((1..48).to_a))
    d = h.stack_rows(by: h["time"].floor(unit: :D))
    assert_equal 2, d.nrow
    assert_equal [2, 24], d["v"].shape
    assert_equal [24.0, 48.0], d["v"].max(axis: 1).to_a
    assert_equal CArray.time(%w[2024-01-01 2024-01-02]).to_a, d.index.to_a
  end
end

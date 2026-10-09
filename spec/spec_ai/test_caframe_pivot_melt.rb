require "test/unit"
require "carray"

# CAFrame#pivot (long -> wide) and CAFrame#melt (wide -> long).

class TestCAFramePivot < Test::Unit::TestCase
  def setup
    @long = CAFrame.new(
      "time"    => CA_INT32([2, 1, 1, 2, 3]),
      "station" => CA_OBJECT(["tokyo", "tokyo", "osaka", "osaka", "tokyo"]),
      "temp"    => CA_FLOAT64([20.0, 10.0, 11.0, 21.0, 30.0]),
    )
  end

  def test_pivot_places_each_value_at_its_pair
    wide = @long.pivot(index: "time", columns: "station", values: "temp")
    assert_equal ["osaka", "tokyo"], wide.column_names
    assert_equal [1, 2, 3], wide.index.to_a
    assert_equal "time", wide.axis_name
    assert_equal [10.0, 20.0, 30.0], wide["tokyo"].to_a
    assert_equal :float64, wide["osaka"].data_type
  end

  def test_pivot_leaves_a_missing_pair_undef
    wide = @long.pivot(index: "time", columns: "station", values: "temp")
    assert_equal [11.0, 21.0, UNDEF], wide["osaka"].to_a
    assert_equal [false, false, true], wide["osaka"].is_masked.to_a
  end

  def test_pivot_carries_a_masked_value
    @long["temp"][3] = UNDEF
    wide = @long.pivot(index: "time", columns: "station", values: "temp")
    assert_equal [false, true, true], wide["osaka"].is_masked.to_a
  end

  def test_pivot_leaves_out_a_row_with_a_masked_key
    @long["station"][4] = UNDEF
    wide = @long.pivot(index: "time", columns: "station", values: "temp")
    assert_equal [10.0, 20.0, UNDEF], wide["tokyo"].to_a
  end

  def test_pivot_raises_on_a_repeated_pair
    @long["time"][4] = 2
    err = assert_raise(ArgumentError) do
      @long.pivot(index: "time", columns: "station", values: "temp")
    end
    assert_match(/time=2, station="tokyo"/, err.message)
  end

  def test_pivot_points_a_repeated_pair_at_aggregate
    @long["time"][4] = 2
    err = assert_raise(ArgumentError) do
      @long.pivot(index: "time", columns: "station", values: "temp")
    end
    assert_match(/aggregate:/, err.message)
  end

  def test_pivot_aggregate_reduces_the_rows_of_each_pair
    @long["time"][4] = 2          # tokyo at time 2 now has 20.0 and 30.0
    wide = @long.pivot(index: "time", columns: "station", values: "temp", aggregate: :mean)
    assert_equal [1, 2], wide.index.to_a
    assert_equal [10.0, 25.0], wide["tokyo"].to_a
    assert_equal [11.0, 21.0], wide["osaka"].to_a
  end

  def test_pivot_aggregate_count_leaves_an_absent_pair_undef
    wide = @long.pivot(index: "time", columns: "station", values: "temp", aggregate: :count)
    assert_equal [1, 1, 1], wide["tokyo"].to_a
    assert_equal [1, 1, UNDEF], wide["osaka"].to_a
  end

  def test_pivot_aggregate_skips_masked_values
    @long["time"][4] = 2
    @long["temp"][4] = UNDEF
    @long["temp"][3] = UNDEF      # osaka at time 2: its only value
    wide = @long.pivot(index: "time", columns: "station", values: "temp", aggregate: :mean)
    assert_equal [10.0, 20.0], wide["tokyo"].to_a
    assert_equal [11.0, UNDEF], wide["osaka"].to_a
  end

  def test_pivot_aggregate_matches_plain_pivot_without_repeats
    plain = @long.pivot(index: "time", columns: "station", values: "temp")
    agg   = @long.pivot(index: "time", columns: "station", values: "temp", aggregate: :max)
    assert_equal plain["tokyo"].to_a, agg["tokyo"].to_a
    assert_equal plain["osaka"].to_a, agg["osaka"].to_a
  end

  def test_pivot_aggregate_keeps_a_face_value
    t = CArray.time(["2024-01-01", "2024-01-03", "2024-01-02"], unit: :D)
    long = CAFrame.new("k" => CA_INT32([0, 0, 1]), "s" => CA_OBJECT(["a", "a", "a"]), "t" => t)
    wide = long.pivot(index: "k", columns: "s", values: "t", aggregate: :max)
    assert_kind_of CATime, wide["a"]
    assert_equal "2024-01-03", wide["a"][0].to_s
  end

  def test_pivot_aggregate_rejects_an_unknown_reduction
    assert_raise(ArgumentError) do
      @long.pivot(index: "time", columns: "station", values: "temp", aggregate: :nonsense)
    end
    assert_raise(ArgumentError) do
      @long.pivot(index: "time", columns: "station", values: "temp", aggregate: "mean")
    end
  end

  def test_pivot_aggregate_needs_a_one_dimensional_value
    long = CAFrame.new("t" => CA_INT32([0, 0]), "k" => CA_OBJECT(["a", "a"]),
                       "w" => CA_FLOAT64([[1, 2], [3, 4]]))
    err = assert_raise(ArgumentError) do
      long.pivot(index: "t", columns: "k", values: "w", aggregate: :mean)
    end
    assert_match(/one-dimensional/, err.message)
  end

  def test_pivot_spreads_several_value_columns
    @long["rh"] = CA_FLOAT64([50, 40, 41, 51, 60])
    wide = @long.pivot(index: "time", columns: "station", values: ["temp", "rh"])
    assert_equal %w[temp_osaka temp_tokyo rh_osaka rh_tokyo], wide.column_names
    assert_equal [10.0, 20.0, 30.0], wide["temp_tokyo"].to_a
    assert_equal [41.0, 51.0, UNDEF], wide["rh_osaka"].to_a
  end

  def test_pivot_names_a_single_value_in_an_array
    wide = @long.pivot(index: "time", columns: "station", values: ["temp"])
    assert_equal %w[temp_osaka temp_tokyo], wide.column_names
  end

  def test_pivot_aggregates_each_value_column
    @long["rh"] = CA_FLOAT64([50, 40, 41, 51, 60])
    @long["time"][4] = 2
    wide = @long.pivot(index: "time", columns: "station", values: ["temp", "rh"],
                       aggregate: :max)
    assert_equal [10.0, 30.0], wide["temp_tokyo"].to_a
    assert_equal [40.0, 60.0], wide["rh_tokyo"].to_a
  end

  def test_pivot_raises_when_value_columns_collide_as_names
    long = CAFrame.new("t" => CA_INT32([0, 0]), "k" => CA_OBJECT(["b_c", "c"]),
                       "a" => CA_FLOAT64([1, 2]), "a_b" => CA_FLOAT64([3, 4]))
    err = assert_raise(ArgumentError) do
      long.pivot(index: "t", columns: "k", values: ["a", "a_b"])
    end
    assert_match(/a_b_c/, err.message)
  end

  def test_pivot_names_columns_by_label_to_s
    long = CAFrame.new("t" => CA_INT32([0, 0, 1]), "id" => CA_INT32([7, 9, 7]),
                       "v" => CA_FLOAT64([1, 2, 3]))
    wide = long.pivot(index: "t", columns: "id", values: "v")
    assert_equal ["7", "9"], wide.column_names
  end

  def test_pivot_raises_when_labels_collide_as_names
    long = CAFrame.new("t" => CA_INT32([0, 0]), "id" => CA_OBJECT([1, "1"]),
                       "v" => CA_FLOAT64([1, 2]))
    assert_raise(ArgumentError) { long.pivot(index: "t", columns: "id", values: "v") }
  end

  def test_pivot_keeps_trailing_dimensions_of_the_value
    long = CAFrame.new("t" => CA_INT32([0, 1, 0]), "k" => CA_OBJECT(["a", "a", "b"]),
                       "w" => CA_FLOAT64([[1, 2], [3, 4], [5, 6]]))
    wide = long.pivot(index: "t", columns: "k", values: "w")
    assert_equal [[1.0, 2.0], [3.0, 4.0]], wide["a"].to_a
    assert_equal [2, 2], wide["b"].shape
    assert_equal [false, false, true, true], wide["b"].is_masked.flatten.to_a
  end

  def test_pivot_index_keeps_its_face
    t = CArray.time(["2024-01-02", "2024-01-01", "2024-01-01"], unit: :D)
    long = CAFrame.new("time" => t, "k" => CA_OBJECT(["a", "a", "b"]),
                       "v" => CA_FLOAT64([2, 1, 3]))
    wide = long.pivot(index: "time", columns: "k", values: "v")
    assert_kind_of CATime, wide.index
    assert_equal "2024-01-01", wide.index[0].to_s
    assert_equal [1.0, 2.0], wide["a"].to_a
  end

  def test_pivot_takes_the_frame_index_as_a_key
    df = @long.set_index("time")
    wide = df.pivot(index: "time", columns: "station", values: "temp")
    assert_equal [1, 2, 3], wide.index.to_a
    assert_equal [10.0, 20.0, 30.0], wide["tokyo"].to_a
  end

  def test_pivot_result_does_not_share_storage
    wide = @long.pivot(index: "time", columns: "station", values: "temp")
    wide["tokyo"][0] = -1.0
    assert_equal 10.0, @long["temp"][1]
  end
end

class TestCAFramePivotGrid < Test::Unit::TestCase
  def setup
    @long = CAFrame.new(
      "time"    => CA_INT32([2, 1, 1, 2, 3]),
      "station" => CA_OBJECT(["tokyo", "tokyo", "osaka", "osaka", "tokyo"]),
      "temp"    => CA_FLOAT64([20.0, 10.0, 11.0, 21.0, 30.0]),
    )
  end

  def test_pivot_grid_returns_the_cells_and_their_labels
    grid, rows, cols = @long.pivot_grid(index: "time", columns: "station", values: "temp")
    assert_equal [3, 2], grid.shape
    assert_equal [1, 2, 3], rows.to_a
    assert_equal ["osaka", "tokyo"], cols.to_a
    assert_equal [[11.0, 10.0], [21.0, 20.0], [UNDEF, 30.0]], grid.to_a
  end

  def test_pivot_grid_matches_pivot
    grid, = @long.pivot_grid(index: "time", columns: "station", values: "temp")
    wide = @long.pivot(index: "time", columns: "station", values: "temp")
    assert_equal wide["osaka"].to_a, grid[nil, 0].to_a
    assert_equal wide["tokyo"].to_a, grid[nil, 1].to_a
  end

  def test_pivot_grid_reduces_along_an_axis
    grid, = @long.pivot_grid(index: "time", columns: "station", values: "temp")
    assert_equal [16.0, 20.0], grid.mean(axis: 0).to_a
  end

  def test_pivot_grid_aggregates
    @long["time"][4] = 2
    grid, rows, = @long.pivot_grid(index: "time", columns: "station", values: "temp",
                                   aggregate: :sum)
    assert_equal [1, 2], rows.to_a
    assert_equal [[11.0, 10.0], [21.0, 50.0]], grid.to_a
  end

  def test_pivot_grid_keeps_trailing_dimensions
    long = CAFrame.new("t" => CA_INT32([0, 1, 0]), "k" => CA_OBJECT(["a", "a", "b"]),
                       "w" => CA_FLOAT64([[1, 2], [3, 4], [5, 6]]))
    grid, = long.pivot_grid(index: "t", columns: "k", values: "w")
    assert_equal [2, 2, 2], grid.shape
    assert_equal [5.0, 6.0], grid[0, 1, nil].to_a
    assert_equal [true, true], grid[1, 1, nil].is_masked.to_a
  end

  def test_pivot_grid_keeps_a_face
    t = CArray.time(["2024-01-02", "2024-01-01", "2024-01-03"], unit: :D)
    long = CAFrame.new("k" => CA_INT32([0, 1, 1]), "s" => CA_OBJECT(["a", "a", "b"]), "t" => t)
    grid, = long.pivot_grid(index: "k", columns: "s", values: "t")
    assert_kind_of CATime, grid
    assert_equal "2024-01-03", grid[1, 1].to_s
  end
end

class TestCAFrameMelt < Test::Unit::TestCase
  def setup
    @wide = CAFrame.new(
      "time"  => CA_INT32([1, 2, 3]),
      "tokyo" => CA_FLOAT64([10, 20, 30]),
      "osaka" => CA_FLOAT64([11, 21, 31]),
    )
  end

  def test_melt_stacks_value_columns
    long = @wide.melt(id: "time")
    assert_equal ["time", "variable", "value"], long.column_names
    assert_equal 6, long.nrow
    assert_equal [1, 2, 3, 1, 2, 3], long["time"].to_a
    assert_equal %w[tokyo tokyo tokyo osaka osaka osaka], long["variable"].to_a
    assert_equal [10.0, 20.0, 30.0, 11.0, 21.0, 31.0], long["value"].to_a
  end

  def test_melt_takes_value_columns_and_names
    long = @wide.melt(id: "time", value_columns: ["osaka"],
                      var_name: "station", value_name: "temp")
    assert_equal ["time", "station", "temp"], long.column_names
    assert_equal [11.0, 21.0, 31.0], long["temp"].to_a
  end

  def test_melt_carries_the_index_as_an_id_column
    long = @wide.set_index("time").melt
    assert_equal ["time", "variable", "value"], long.column_names
    assert_equal [1, 2, 3, 1, 2, 3], long["time"].to_a
  end

  def test_melt_keeps_masked_cells
    @wide["osaka"][1] = UNDEF
    long = @wide.melt(id: "time")
    assert_equal [false, false, false, false, true, false], long["value"].is_masked.to_a
  end

  def test_melt_is_a_view_of_the_wide_frame
    long = @wide.melt(id: "time")
    long["value"][4] = -1.0
    assert_equal -1.0, @wide["osaka"][1]
  end

  def test_melt_raises_on_mixed_value_types
    @wide["osaka"] = CA_INT32([11, 21, 31])
    err = assert_raise(ArgumentError) { @wide.melt(id: "time") }
    assert_match(/cast them to one type/, err.message)
  end

  def test_melt_raises_when_a_name_is_both_id_and_value
    assert_raise(ArgumentError) { @wide.melt(id: "time", value_columns: ["time"]) }
  end

  def test_melt_then_pivot_gives_the_wide_frame_back
    wide = @wide.melt(id: "time").pivot(index: "time", columns: "variable", values: "value")
    assert_equal [1, 2, 3], wide.index.to_a
    assert_equal @wide["tokyo"].to_a, wide["tokyo"].to_a
    assert_equal @wide["osaka"].to_a, wide["osaka"].to_a
  end
end

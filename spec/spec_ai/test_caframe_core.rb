require "test/unit"
require "carray"

# CAFrame — minimal vertical spine (MEMO_DATAFRAME_ON_CARRAY.md §3, §13.2, §15).
#
# Covers construction + the df[] total function (column escape: one CArray /
# Array<CArray> / row Hash / positional slice / boolean filter / integer
# gather), select (column-projection view-frame), the filter block,
# view-frame aliasing vs copy independence, N-D columns,
# metadata readers, set_index, and the error contracts.

class TestCAFrameConstruction < Test::Unit::TestCase
  def test_bare_inline_hash
    df = CAFrame.new("a" => CA_INT32([1, 2, 3]), "b" => CA_FLOAT64([1.0, 2.0, 3.0]))
    assert_equal 3, df.nrow
    assert_equal 2, df.nvar
    assert_equal ["a", "b"], df.variable_names
  end

  def test_explicit_hash_with_options
    idx = CA_INT32([10, 20])
    df = CAFrame.new({ "v" => CA_FLOAT64([1.0, 2.0]) }, axis_name: "t", index: idx)
    assert_equal "t", df.axis_name
    assert_equal [10, 20], df.index.to_a
  end

  def test_bare_symbol_key_rejected
    # Column keys are strings (memo §3.7); a bare symbol key is ambiguous
    # with the :axis_name / :index options, so it is rejected loudly.
    assert_raise(ArgumentError) { CAFrame.new(a: CA_INT32([1, 2])) }
  end

  def test_symbol_key_in_explicit_hash_coerced
    # An explicit column hash has no option ambiguity; symbol keys become
    # strings so the internal Hash is uniformly string-keyed.
    df = CAFrame.new({ a: CA_INT32([1, 2]) })
    assert_equal ["a"], df.variable_names
    assert_equal [1, 2], df["a"].to_a
  end

  def test_ruby_array_column_coerced
    df = CAFrame.new("a" => [1, 2, 3])
    assert_kind_of CArray, df["a"]
    assert_equal [1, 2, 3], df["a"].to_a
  end

  def test_axis0_length_mismatch_raises
    assert_raise(ArgumentError) do
      CAFrame.new("a" => CA_INT32([1, 2]), "b" => CA_INT32([1, 2, 3]))
    end
  end

  def test_trailing_shape_free_per_column
    # scalar / 2-vector / 3x3 all agree on axis-0 = 3 (memo §3.2).
    df = CAFrame.new(
      "temp" => CA_FLOAT64([1.0, 2.0, 3.0]),
      "wind" => CA_FLOAT64([[1, 2], [3, 4], [5, 6]]),
      "cov"  => CA_FLOAT64(CArray.float64(3, 3, 3) { 0 }),
    )
    assert_equal 3, df.nrow
    assert_equal [3, 2], df["wind"].shape
    assert_equal [3, 3, 3], df["cov"].shape
  end

  def test_index_length_must_match
    assert_raise(ArgumentError) do
      CAFrame.new({ "v" => CA_FLOAT64([1.0, 2.0]) }, index: CA_INT32([1, 2, 3]))
    end
  end

  def test_non_carray_column_raises
    assert_raise(ArgumentError) { CAFrame.new("a" => "not a column") }
  end
end

class TestCAFrameColumnAccess < Test::Unit::TestCase
  def setup
    @df = CAFrame.new(
      "station" => CA_OBJECT(["tokyo", "osaka", "tokyo"]),
      "temp"    => CA_FLOAT64([22.1, 25.3, 19.0]),
      "wind"    => CA_FLOAT64([[1.2, -0.3], [2.1, 0.5], [0.0, 0.0]]),
    )
  end

  def test_string_returns_raw_carray
    col = @df["temp"]
    assert_kind_of CArray, col
    assert_equal [22.1, 25.3, 19.0], col.to_a
  end

  def test_column_is_the_stored_alias
    # df["col"] returns the storage itself; writing through it mutates the
    # frame (memo §3.6 / §4.3, no defensive copy).
    @df["temp"][0] = 99.0
    assert_equal 99.0, @df["temp"][0]
  end

  def test_missing_column_raises
    assert_raise(KeyError) { @df["nope"] }
  end

  def test_multi_string_returns_array_of_columns
    cols = @df["temp", "wind"]
    assert_kind_of Array, cols
    assert_equal 2, cols.size
    assert_kind_of CArray, cols[0]
    assert_kind_of CArray, cols[1]
    assert_equal [22.1, 25.3, 19.0], cols[0].to_a
    assert_equal [3, 2], cols[1].shape
  end

  def test_multi_string_destructures
    t, wind = @df["temp", "wind"]
    assert_equal [22.1, 25.3, 19.0], t.to_a
    assert_equal [3, 2], wind.shape
  end

  def test_multi_string_columns_are_aliases
    # The escaped columns are the stored CArrays; writing through mutates.
    t, = @df["temp", "wind"]
    t[1] = -7.0
    assert_equal(-7.0, @df["temp"][1])
  end

  def test_multi_key_must_all_be_strings
    assert_raise(ArgumentError) { @df["temp", 0] }
  end

  def test_multi_key_missing_column_raises
    assert_raise(KeyError) { @df["temp", "nope"] }
  end
end

# df["name"] = ... : the column half of []=.  The key picks the axis exactly
# as it does when reading (memo §13.2), so a String names a column and
# anything else still selects rows.  An assignment can only mutate the
# receiver -- Ruby hands the right-hand side back -- so these are all
# in-place on this frame's own column set (§12-B).
class TestCAFrameColumnAssign < Test::Unit::TestCase
  def setup
    @df = CAFrame.new("a" => CA_FLOAT64([1, 2, 3]), "b" => CA_INT32([4, 5, 6]))
  end

  def test_rebinding_a_name_keeps_the_column_order
    @df["a"] = CA_FLOAT64([9, 9, 9])
    assert_equal [9.0, 9.0, 9.0], @df["a"].to_a
    assert_equal ["a", "b"], @df.variable_names
  end

  def test_a_new_name_is_added_in_place
    @df["c"] = CA_INT32([7, 8, 9])
    assert_equal ["a", "b", "c"], @df.variable_names
    assert_equal [7, 8, 9], @df["c"].to_a
  end

  def test_the_right_hand_side_is_coerced_like_a_constructor_column
    @df["c"] = [1, 2, 3]
    assert_kind_of CArray, @df["c"]
  end

  def test_the_axis_0_length_is_enforced_here
    # memo §12-A: rebinding is the one place a column enters an existing
    # frame, so it is where the length invariant is checked.
    assert_raise(ArgumentError) { @df["c"] = CA_FLOAT64([1, 2]) }
  end

  def test_a_scalar_right_hand_side_is_refused
    # No implicit broadcast; write CArray.float64(df.nrow) { 3 }.
    assert_raise(ArgumentError) { @df["c"] = 3 }
  end

  def test_a_frame_right_hand_side_is_refused
    assert_raise(ArgumentError) { @df["c"] = @df.copy }
  end

  def test_rebinding_does_not_write_through
    # The binding moves, the data does not -- the same physical rule as cast.
    col = CA_FLOAT64([1, 2, 3])
    df  = CAFrame.new("a" => col)
    df["a"] = CA_FLOAT64([9, 9, 9])
    assert_equal [1.0, 2.0, 3.0], col.to_a
  end

  def test_nil_deletes_the_column
    @df["a"] = nil
    assert_equal ["b"], @df.variable_names
    assert_raise(KeyError) { @df["zzz"] = nil }
  end

  def test_deleting_every_column_releases_the_row_count
    @df["a"] = nil
    @df["b"] = nil
    assert_equal 0, @df.nvar
    assert_equal 0, @df.nrow
    @df["c"] = CA_INT32([1, 2])     # the frame is free to take a new N
    assert_equal 2, @df.nrow
  end

  def test_undef_masks_the_column_and_writes_through
    col = CA_FLOAT64([1, 2, 3])
    df  = CAFrame.new("a" => col)
    df["a"] = UNDEF
    assert_equal [UNDEF, UNDEF, UNDEF], df["a"].to_a
    assert_equal [UNDEF, UNDEF, UNDEF], col.to_a      # visible through the alias
  end

  def test_an_empty_frame_takes_its_row_count_from_the_first_column
    df = CAFrame.new
    df["a"] = CA_FLOAT64([1, 2, 3])
    assert_equal 3, df.nrow
    assert_equal ["a"], df.variable_names
  end

  def test_the_index_name_is_not_a_column
    df = CAFrame.new({ "x" => CA_FLOAT64([1, 2]) },
                     index: CA_INT32([10, 20]), axis_name: "t")
    assert_raise(ArgumentError) { df["t"] = CA_INT32([1, 2]) }
  end

  def test_membership_stays_local_to_this_frame
    view = @df[0..1]
    view["c"] = CA_INT32([1, 2])
    assert_equal ["a", "b", "c"], view.variable_names
    assert_equal ["a", "b"], @df.variable_names
  end

  def test_more_than_one_key_is_refused
    assert_raise(ArgumentError) { @df["a", "b"] = CA_FLOAT64([1, 2, 3]) }
  end

  def test_the_row_forms_are_untouched
    df = CAFrame.new("a" => CA_FLOAT64([1, 2, 3]), "b" => CA_INT32([4, 5, 6]))
    df[0] = UNDEF
    assert_equal UNDEF, df["a"][0]
    df[0..0] = nil
    assert_equal 2, df.nrow
  end
end

class TestCAFrameSelect < Test::Unit::TestCase
  def setup
    @df = CAFrame.new(
      "station" => CA_OBJECT(["tokyo", "osaka", "tokyo"]),
      "temp"    => CA_FLOAT64([22.1, 25.3, 19.0]),
      "wind"    => CA_FLOAT64([[1.2, -0.3], [2.1, 0.5], [0.0, 0.0]]),
    )
  end

  def test_select_returns_subset_frame
    sub = @df.select("temp", "wind")
    assert_kind_of CAFrame, sub
    assert_equal ["temp", "wind"], sub.variable_names
    assert_equal 3, sub.nrow
  end

  def test_select_single_name_still_a_frame
    # select never collapses (unlike df[...]); one name is still a frame.
    sub = @df.select("temp")
    assert_kind_of CAFrame, sub
    assert_equal ["temp"], sub.variable_names
  end

  def test_select_columns_are_aliases
    # A column-projection view-frame shares storage with the parent (§3.6).
    sub = @df.select("temp", "wind")
    sub["temp"][1] = -7.0
    assert_equal(-7.0, @df["temp"][1])
  end

  def test_select_chains_with_filter
    sub = @df.select("station", "temp").filter { |f| f["temp"] > 20 }
    assert_kind_of CAFrame, sub
    assert_equal ["station", "temp"], sub.variable_names
    assert_equal ["tokyo", "osaka"], sub["station"].to_a
    assert_equal 2, sub.nrow
  end

  def test_select_missing_column_raises
    assert_raise(KeyError) { @df.select("temp", "nope") }
  end

  def test_select_requires_a_name
    assert_raise(ArgumentError) { @df.select }
  end
end

class TestCAFrameRowAccess < Test::Unit::TestCase
  def setup
    @df = CAFrame.new(
      "station" => CA_OBJECT(["tokyo", "osaka", "tokyo"]),
      "temp"    => CA_FLOAT64([22.1, 25.3, 19.0]),
      "wind"    => CA_FLOAT64([[1.2, -0.3], [2.1, 0.5], [0.0, 0.0]]),
    )
  end

  def test_integer_returns_ruby_hash
    row = @df[0]
    assert_kind_of Hash, row
    assert_equal "tokyo", row["station"]
    assert_equal 22.1, row["temp"]
  end

  def test_row_nd_column_is_trailing_slice
    row = @df[0]
    assert_kind_of CArray, row["wind"]
    assert_equal [1.2, -0.3], row["wind"].to_a
  end

  def test_negative_index
    assert_equal "tokyo", @df[-1]["station"]
  end

  def test_out_of_range_raises
    assert_raise(IndexError) { @df[3] }
    assert_raise(IndexError) { @df[-4] }
  end

  def test_row_includes_index_under_axis_name
    df = @df.set_index("station")
    row = df[1]
    assert_equal "osaka", row["station"]
    assert_equal 25.3, row["temp"]
  end
end

class TestCAFramePositionSlice < Test::Unit::TestCase
  def setup
    @df = CAFrame.new(
      "temp" => CA_FLOAT64([22.1, 25.3, 19.0, 30.0]),
      "wind" => CA_FLOAT64([[1, 2], [3, 4], [5, 6], [7, 8]]),
    )
  end

  def test_integer_range_returns_view_frame
    sub = @df[0..1]
    assert_kind_of CAFrame, sub
    assert_equal 2, sub.nrow
    assert_equal [22.1, 25.3], sub["temp"].to_a
  end

  def test_slice_carries_trailing_dims
    sub = @df[1..2]
    assert_equal [[3.0, 4.0], [5.0, 6.0]], sub["wind"].to_a
  end

  def test_slice_is_view_write_through
    sub = @df[0..1]
    sub["temp"][0] = -1.0
    assert_equal(-1.0, @df["temp"][0])
  end

  def test_label_range_rejected
    # non-integer range endpoints are not positional (memo §13.2, §15).
    assert_raise(ArgumentError) { @df["a".."b"] }
  end

  def test_chain_row_then_columns
    m = @df[0..1]["temp"]
    assert_equal [22.1, 25.3], m.to_a
  end

  def test_head_returns_first_n_view_frame
    h = @df.head(2)
    assert_kind_of CAFrame, h
    assert_equal 2, h.nrow
    assert_equal [22.1, 25.3], h["temp"].to_a
    assert_equal [[1.0, 2.0], [3.0, 4.0]], h["wind"].to_a
  end

  def test_tail_returns_last_n_view_frame
    t = @df.tail(2)
    assert_equal 2, t.nrow
    assert_equal [19.0, 30.0], t["temp"].to_a
    assert_equal [[5.0, 6.0], [7.0, 8.0]], t["wind"].to_a
  end

  def test_head_default_is_five_and_clamps
    assert_equal 4, @df.head.nrow    # default 5, clamped to nrow
    assert_equal 4, @df.head(100).nrow
    assert_equal 4, @df.tail(100).nrow
  end

  def test_head_tail_zero_is_empty
    assert_equal 0, @df.head(0).nrow
    assert_equal 0, @df.tail(0).nrow
  end

  def test_head_negative_raises
    assert_raise(ArgumentError) { @df.head(-1) }
    assert_raise(ArgumentError) { @df.tail(-1) }
  end

  def test_head_is_view_write_through
    @df.head(1)["temp"][0] = -1.0
    assert_equal(-1.0, @df["temp"][0])
  end

  def test_head_carries_index
    df = @df.set_index("temp")
    assert_equal [22.1, 25.3], df.head(2).index.to_a
    assert_equal [19.0, 30.0], df.tail(2).index.to_a
  end
end

class TestCAFrameAtLabel < Test::Unit::TestCase
  def setup
    @df = CAFrame.new(
      "station" => CA_OBJECT(["tokyo", "osaka", "kyoto"]),
      "temp"    => CA_FLOAT64([22.1, 25.3, 19.0]),
      "wind"    => CA_FLOAT64([[1, 2], [3, 4], [5, 6]]),
    ).set_index("station")
  end

  def test_at_returns_single_row_hash
    row = @df.at("osaka")
    assert_kind_of Hash, row
    assert_equal "osaka", row["station"]
    assert_equal 25.3, row["temp"]
  end

  def test_at_carries_nd_column_slice
    assert_equal [3.0, 4.0], @df.at("osaka")["wind"].to_a
  end

  def test_at_missing_label_raises_key_error
    assert_raise(KeyError) { @df.at("nagoya") }
  end

  def test_at_duplicate_label_raises
    df = CAFrame.new("k" => CA_INT32([10, 20, 10]),
                     "v" => CA_FLOAT64([1, 2, 3])).set_index("k")
    assert_raise(ArgumentError) { df.at(10) }
    assert_equal 2.0, df.at(20)["v"]   # unique label still works
  end

  def test_at_without_index_raises
    df = CAFrame.new("v" => CA_INT32([1, 2, 3]))
    assert_raise(ArgumentError) { df.at(0) }
  end
end

class TestCAFrameFilterAndGather < Test::Unit::TestCase
  def setup
    @df = CAFrame.new(
      "station" => CA_OBJECT(["tokyo", "osaka", "kyoto"]),
      "temp"    => CA_FLOAT64([22.1, 25.3, 19.0]),
      "rh"      => CA_FLOAT64([40.0, 60.0, 45.0]),
    )
  end

  def test_boolean_carray_key_filters
    sub = @df[@df["temp"] > 20]
    assert_equal 2, sub.nrow
    assert_equal ["tokyo", "osaka"], sub["station"].to_a
  end

  def test_integer_carray_key_gathers
    sub = @df[CA_INT32([2, 0])]
    assert_equal ["kyoto", "tokyo"], sub["station"].to_a
    assert_equal [19.0, 22.1], sub["temp"].to_a
  end

  def test_filter_block
    sub = @df.filter { |f| (f["temp"] > 20) & (f["rh"] < 50) }
    assert_equal 1, sub.nrow
    assert_equal "tokyo", sub["station"][0]
  end

  def test_filter_block_receives_frame
    seen = nil
    @df.filter { |f| seen = f; f["temp"] > 0 }
    assert_same @df, seen
  end

  def test_filter_non_boolean_return_raises
    assert_raise(ArgumentError) { @df.filter { |f| f["temp"] } }
  end

  def test_bad_carray_dtype_key_raises
    assert_raise(ArgumentError) { @df[CA_FLOAT64([1.0, 2.0])] }
  end

  def test_filter_carries_index
    df = @df.set_index("station")
    sub = df.filter { |f| f["temp"] > 20 }
    assert_equal ["tokyo", "osaka"], sub.index.to_a
  end
end

# filter keep_masked: — a masked (UNDEF) selector cell means membership is
# genuinely undetermined (PROPOSAL_KLEENE_BOOLEAN_LOGIC §9, CLAUDE.md 将来の
# リファクタリング候補). Default drops it; keep_masked: true carries the UNDEF
# forward as masked data cells while keeping the index value present.
class TestCAFrameFilterKeepMasked < Test::Unit::TestCase
  def setup
    # row 1's predicate input is masked -> its selector cell is UNDEF
    @df = CAFrame.new(
      "a" => CA_INT32([10, 20, 30, 40]),
      "b" => CA_FLOAT64([0.5, 1.5, 2.5, 3.5]),
    )
    @df["a"][2] = UNDEF   # selector a > 15 -> [F, T, U, T]
  end

  def test_default_drops_undetermined_row
    sub = @df.filter { |f| f["a"] > 15 }
    assert_equal 2, sub.nrow
    assert_equal [20, 40], sub["a"].to_a
    assert_equal [1.5, 3.5], sub["b"].to_a
  end

  def test_keep_masked_carries_undef_forward
    sub = @df.filter(keep_masked: true) { |f| f["a"] > 15 }
    assert_equal 3, sub.nrow
    # true rows keep their values; the undetermined row's cells are masked
    assert_equal [20, nil, 40], sub["a"].to_a.map { |v| v == UNDEF ? nil : v }
    assert_equal [false, true, false], sub["a"].mask.to_a
    assert_equal [false, true, false], sub["b"].mask.to_a
  end

  def test_keep_masked_does_not_corrupt_parent
    @df.filter(keep_masked: true) { |f| f["a"] > 15 }
    assert_equal [10, 20, nil, 40], @df["a"].to_a.map { |v| v == UNDEF ? nil : v }
    assert_equal [0.5, 1.5, 2.5, 3.5], @df["b"].to_a
  end

  def test_keep_masked_without_masked_selector_equals_drop
    df = CAFrame.new("a" => CA_INT32([10, 20, 30, 40]))
    drop = df.filter { |f| f["a"] > 15 }
    keep = df.filter(keep_masked: true) { |f| f["a"] > 15 }
    assert_equal drop["a"].to_a, keep["a"].to_a
    assert_equal 3, keep.nrow
  end

  def test_keep_masked_preserves_index_on_undetermined_row
    df = CAFrame.new({ "v" => CA_INT32([10, 20, 30, 40]) },
                     index: CA_INT32([100, 200, 300, 400]), axis_name: "id")
    df["v"][2] = UNDEF
    sub = df.filter(keep_masked: true) { |f| f["v"] > 15 }
    assert_equal "id", sub.axis_name
    assert_equal [200, 300, 400], sub.index.to_a   # index value present, unmasked
    assert_equal false, sub.index.has_mask?        # the index carries no masked cell
  end

  def test_keep_masked_all_undetermined
    df = CAFrame.new("v" => CA_INT32([1, 2, 3]))
    df["v"][0..2] = UNDEF
    keep = df.filter(keep_masked: true) { |f| f["v"] > 0 }
    assert_equal 3, keep.nrow
    assert_equal [true, true, true], keep["v"].mask.to_a
    drop = df.filter { |f| f["v"] > 0 }
    assert_equal 0, drop.nrow
  end
end

class TestCAFrameCopyAndMetadata < Test::Unit::TestCase
  def setup
    @df = CAFrame.new(
      "a" => CA_INT32([1, 2, 3]),
      "b" => CA_FLOAT64([1.0, 2.0, 3.0]),
    )
  end

  def test_copy_is_independent
    c = @df.copy
    c["a"][0] = 99
    assert_equal 1, @df["a"][0]
  end

  def test_variables_returns_fresh_array
    v = @df.variable_names
    v << "sneaky"
    assert_equal ["a", "b"], @df.variable_names
  end

  def test_data_types
    assert_equal({ "a" => :int32, "b" => :float64 }, @df.data_types)
  end

  def test_nrow_nvar
    assert_equal 3, @df.nrow
    assert_equal 2, @df.nvar
  end
end

class TestCAFrameIndex < Test::Unit::TestCase
  def test_set_index_moves_column
    df = CAFrame.new("t" => CA_INT32([1, 2, 3]), "v" => CA_FLOAT64([9, 8, 7]))
    di = df.set_index("t")
    assert_equal "t", di.axis_name
    assert_equal [1, 2, 3], di.index.to_a
    assert_equal ["v"], di.variable_names
  end

  def test_set_index_missing_column_raises
    df = CAFrame.new("v" => CA_FLOAT64([1.0]))
    assert_raise(KeyError) { df.set_index("nope") }
  end

  def test_reset_index_restores_column
    df = CAFrame.new("t" => CA_INT32([1, 2]), "v" => CA_FLOAT64([9, 8])).set_index("t")
    r = df.reset_index
    assert_nil r.index
    assert_equal ["t", "v"], r.variable_names
  end

  def test_index_stays_1d_with_nd_columns
    df = CAFrame.new(
      "t"    => CA_INT32([1, 2, 3]),
      "wind" => CA_FLOAT64([[1, 2], [3, 4], [5, 6]]),
    ).set_index("t")
    assert_equal 1, df.index.ndim
    assert_equal [3], df.index.shape
  end
end

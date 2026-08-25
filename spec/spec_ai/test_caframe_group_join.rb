require "test/unit"
require "carray"

# CAFrame group_by / join (MEMO_DATAFRAME_ON_CARRAY.md §5, §11.6, §11.7, §13.3).
#
# group_by routes through categorize -> group_by_category (single / composite
# / external keys, masked rows excluded). aggregate (Symbol + Proc), table
# escape, and the grp.mean shortcut. join delegates to locate_addr (left) and
# align_addr (inner/outer/right), gathering columns via project including the
# N-D flat-address expansion.

class TestCAFrameGroupBy < Test::Unit::TestCase
  def setup
    @df = CAFrame.new(
      "station" => CA_OBJECT(["tokyo", "osaka", "tokyo", "osaka", "kyoto"]),
      "temp"    => CA_FLOAT64([22.1, 25.3, 19.0, 30.0, 15.0]),
      "wind"    => CA_FLOAT64([[1, 2], [3, 4], [5, 6], [7, 8], [9, 10]]),
    )
  end

  def test_group_by_returns_grouped_frame
    grp = @df.group_by("station")
    assert_kind_of GroupedFrame, grp
    assert_equal 3, grp.ngroup
    assert_equal ["tokyo", "osaka", "kyoto"], grp.labels
  end

  def test_grp_exposes_group_iterator
    it = @df.group_by("station")["temp"]
    assert_kind_of CACategoricalIterator, it
    assert_equal [20.55, 27.65, 15.0], it.mean.to_a
  end

  def test_aggregate_symbol_reductions
    stat = @df.group_by("station").aggregate(
      "temp_mean" => ["temp", :mean],
      "temp_max"  => ["temp", :max],
    )
    assert_equal ["temp_mean", "temp_max"], stat.variable_names
    assert_equal [20.55, 27.65, 15.0], stat["temp_mean"].to_a
    assert_equal [22.1, 30.0, 15.0], stat["temp_max"].to_a
  end

  def test_aggregate_index_is_group_labels
    stat = @df.group_by("station").aggregate("m" => ["temp", :mean])
    assert_equal "station", stat.axis_name
    assert_equal ["tokyo", "osaka", "kyoto"], stat.index.to_a
  end

  def test_aggregate_proc_reduction_nd_column
    stat = @df.group_by("station").aggregate(
      "wind_mean" => ["wind", ->(c) { c.mean(axis: 0) }],
    )
    # tokyo rows: [1,2] and [5,6] -> mean [3,4]
    assert_equal [3.0, 4.0], stat["wind_mean"][0].to_a
  end

  def test_table_escape_cross_column
    t = @df.group_by("station").table do |g|
      { "n" => g.nrow, "tmax" => g["temp"].max }
    end
    assert_equal [2, 2, 1], t["n"].to_a
    assert_equal [22.1, 30.0, 15.0], t["tmax"].to_a
  end

  def test_table_g_is_view_frame
    seen = nil
    @df.group_by("station").table { |g| seen = g; { "n" => g.nrow } }
    assert_kind_of CAFrame, seen
  end

  def test_escape_path_high_ngroup_membership_and_order
    # The escape helpers (table / Proc) ride the categorical grouping plan
    # (perm/offsets), not a per-group O(N) scan. Verify at high ngroup that
    # each group gets exactly its rows, in ascending original order.
    ng = 50
    n  = 1000
    df = CAFrame.new(
      "key" => CArray.int32(n) { |i| i % ng },
      "idx" => CArray.int32(n) { |i| i },
    )
    res = df.group_by("key").table { |g| { "members" => g["idx"].to_a } }
    assert_equal (0...ng).to_a, res.index.to_a
    ng.times do |k|
      assert_equal (k...n).step(ng).to_a, res["members"][k]
    end
  end

  def test_mean_shortcut_over_numeric_scalar_columns
    m = @df.group_by("station").mean
    # object "station" and N-D "wind" are skipped; only "temp".
    assert_equal ["temp"], m.variable_names
    assert_equal [20.55, 27.65, 15.0], m["temp"].to_a
  end

  def test_composite_key
    df = CAFrame.new(
      "a" => CA_OBJECT(["x", "x", "y"]),
      "b" => CA_INT32([1, 2, 1]),
      "v" => CA_FLOAT64([10, 20, 30]),
    )
    stat = df.group_by("a", "b").aggregate("s" => ["v", :sum])
    assert_equal "group", stat.axis_name
    assert_equal [["x", 1], ["x", 2], ["y", 1]], stat.index.to_a
    assert_equal [10.0, 20.0, 30.0], stat["s"].to_a
  end

  def test_external_carray_key
    df = CAFrame.new("v" => CA_FLOAT64([1, 2, 3, 4]))
    stat = df.group_by(CA_INT32([0, 1, 0, 1])).aggregate("s" => ["v", :sum])
    assert_equal [4.0, 6.0], stat["s"].to_a
  end

  def test_external_key_length_mismatch_raises
    df = CAFrame.new("v" => CA_FLOAT64([1, 2, 3]))
    assert_raise(ArgumentError) { df.group_by(CA_INT32([0, 1])) }
  end

  def test_masked_key_rows_excluded
    st = CA_OBJECT(["a", "b", "a"])
    st[1] = UNDEF
    df = CAFrame.new("st" => st, "v" => CA_FLOAT64([10, 20, 30]))
    stat = df.group_by("st").aggregate("s" => ["v", :sum])
    # only group "a": 10 + 30
    assert_equal [40.0], stat["s"].to_a
  end

  def test_empty_group_by_raises
    assert_raise(ArgumentError) { @df.group_by }
  end
end

class TestCAFrameJoin < Test::Unit::TestCase
  def setup
    @df = CAFrame.new(
      "station" => CA_OBJECT(["tokyo", "osaka", "tokyo"]),
      "temp"    => CA_FLOAT64([22.1, 25.3, 19.0]),
    )
    @meta = CAFrame.new(
      "station" => CA_OBJECT(["tokyo", "osaka", "kyoto"]),
      "lat"     => CA_FLOAT64([35.7, 34.7, 35.0]),
      "wvec"    => CA_FLOAT64([[1, 2], [3, 4], [5, 6]]),
    )
  end

  def test_left_join_is_row_preserving
    j = @df.join(@meta, on: "station")
    assert_equal 3, j.nrow
    assert_equal ["station", "temp", "lat", "wvec"], j.variable_names
    assert_equal [22.1, 25.3, 19.0], j["temp"].to_a
    assert_equal [35.7, 34.7, 35.7], j["lat"].to_a
  end

  def test_left_join_nd_column_gathered
    j = @df.join(@meta, on: "station")
    # tokyo -> [1,2], osaka -> [3,4], tokyo -> [1,2]
    assert_equal [[1.0, 2.0], [3.0, 4.0], [1.0, 2.0]], j["wvec"].to_a
  end

  def test_left_join_miss_is_undef
    df = CAFrame.new("station" => CA_OBJECT(["tokyo", "nagoya"]), "t" => CA_FLOAT64([1, 2]))
    j = df.join(@meta, on: "station")
    assert_equal 35.7, j["lat"][0]
    assert_equal UNDEF, j["lat"][1]
    # N-D miss row fully masked
    assert_equal UNDEF, j["wvec"][1, 0]
    assert_equal UNDEF, j["wvec"][1, 1]
  end

  def test_inner_join
    j = @df.join(@meta, on: "station", how: :inner)
    assert_equal ["tokyo", "osaka"], j["station"].to_a
    assert_equal [35.7, 34.7], j["lat"].to_a
  end

  def test_outer_join
    j = @df.join(@meta, on: "station", how: :outer)
    assert_equal ["tokyo", "osaka", "kyoto"], j["station"].to_a
    assert_equal 22.1, j["temp"][0]
    assert_equal UNDEF, j["temp"][2] # kyoto has no left row
    assert_equal 35.0, j["lat"][2]
  end

  def test_left_join_keeps_index
    d = CAFrame.new(
      "id" => CA_INT32([100, 200, 300]),
      "station" => CA_OBJECT(["tokyo", "osaka", "tokyo"]),
      "temp" => CA_FLOAT64([1, 2, 3]),
    ).set_index("id")
    j = d.join(@meta, on: "station")
    assert_equal "id", j.axis_name
    assert_equal [100, 200, 300], j.index.to_a
  end

  def test_align_join_carries_left_index_by_a_idx
    # Index rides a_idx just like the left columns: rows with no left match
    # (outer/right) become UNDEF, staying consistent with the left join.
    d = CAFrame.new(
      "id" => CA_INT32([100, 200, 300]),
      "station" => CA_OBJECT(["tokyo", "osaka", "tokyo"]),
      "temp" => CA_FLOAT64([1, 2, 3]),
    ).set_index("id")
    j = d.join(@meta, on: "station", how: :outer)
    assert_equal "id", j.axis_name
    # aligned key order: tokyo, osaka, kyoto -> left ids 100, 200, (miss)
    assert_equal 100, j.index[0]
    assert_equal 200, j.index[1]
    assert_equal UNDEF, j.index[2]
  end

  def test_inner_join_carries_left_index
    d = CAFrame.new(
      "id" => CA_INT32([100, 200, 300]),
      "station" => CA_OBJECT(["tokyo", "osaka", "tokyo"]),
      "temp" => CA_FLOAT64([1, 2, 3]),
    ).set_index("id")
    j = d.join(@meta, on: "station", how: :inner)
    # common = tokyo, osaka; a_idx picks left rows 0 and 1 -> ids 100, 200
    assert_equal [100, 200], j.index.to_a
  end

  def test_collision_auto_suffixes_both_sides
    other = CAFrame.new("station" => CA_OBJECT(["tokyo", "osaka"]),
                        "temp" => CA_FLOAT64([9, 8]), "lat" => CA_FLOAT64([35.7, 34.7]))
    j = @df.join(other, on: "station")
    # key stays single; colliding "temp" suffixed both sides; "lat" untouched
    assert_equal ["station", "temp_left", "temp_right", "lat"], j.variable_names
    assert_equal [22.1, 25.3, 19.0], j["temp_left"].to_a
    assert_equal [9.0, 8.0, 9.0], j["temp_right"].to_a
  end

  def test_custom_suffixes
    other = CAFrame.new("station" => CA_OBJECT(["tokyo"]), "temp" => CA_FLOAT64([9]))
    j = @df.join(other, on: "station", suffixes: ["_obs", "_fcst"])
    assert_equal ["station", "temp_obs", "temp_fcst"], j.variable_names
  end

  def test_suffixes_false_raises_on_collision
    other = CAFrame.new("station" => CA_OBJECT(["tokyo"]), "temp" => CA_FLOAT64([9]))
    assert_raise(ArgumentError) { @df.join(other, on: "station", suffixes: false) }
  end

  def test_no_collision_no_suffix
    j = @df.join(@meta, on: "station")
    assert_equal ["station", "temp", "lat", "wvec"], j.variable_names
  end

  def test_inner_join_suffixes_collision
    other = CAFrame.new("station" => CA_OBJECT(["tokyo", "osaka"]), "temp" => CA_FLOAT64([9, 8]))
    j = @df.join(other, on: "station", how: :inner)
    assert_includes j.variable_names, "temp_left"
    assert_includes j.variable_names, "temp_right"
  end

  def test_bad_suffixes_raise
    other = CAFrame.new("station" => CA_OBJECT(["tokyo"]), "temp" => CA_FLOAT64([9]))
    assert_raise(ArgumentError) { @df.join(other, on: "station", suffixes: ["_x"]) }
  end

  def test_secondary_suffix_collision_raises
    left  = CAFrame.new("station" => CA_OBJECT(["tokyo"]),
                        "temp" => CA_FLOAT64([1]), "temp_left" => CA_FLOAT64([9]))
    right = CAFrame.new("station" => CA_OBJECT(["tokyo"]), "temp" => CA_FLOAT64([2]))
    assert_raise(ArgumentError) { left.join(right, on: "station") }
  end

  def test_unknown_how_raises
    assert_raise(ArgumentError) { @df.join(@meta, on: "station", how: :sideways) }
  end
end

class TestCAFrameAlign < Test::Unit::TestCase
  def setup
    # 10-min series (minutes) with a gap 720 -> 760 (750,740,730 missing)
    @df = CAFrame.new(
      "time" => CA_INT64([700, 710, 720, 760, 770]),
      "temp" => CA_FLOAT64([0.8, 0.7, 0.6, 0.4, 0.3]),
      "rh"   => CA_INT32([53, 55, 58, 62, 60]),
    )
    @ref = CA_INT64([700, 710, 720, 730, 740, 750, 760, 770])
  end

  def test_align_inserts_missing_rows_as_undef
    out = @df.align("time", @ref)
    assert_equal 8, out.nrow
    assert_equal @ref.to_a, out["time"].to_a               # key column = reference
    assert_equal [0.8, 0.7, 0.6, UNDEF, UNDEF, UNDEF, 0.4, 0.3], out["temp"].to_a
    assert_equal [53, 55, 58, UNDEF, UNDEF, UNDEF, 62, 60], out["rh"].to_a
  end

  def test_align_keeps_int_type_no_float_promotion
    out = @df.align("time", @ref)
    assert_equal :int32, out["rh"].data_type              # gaps are UNDEF, not float NaN
  end

  def test_align_on_index
    out = @df.set_index("time").align("time", @ref)
    assert_equal "time", out.axis_name
    assert_equal @ref.to_a, out.index.to_a
    assert_equal [0.8, 0.7, 0.6, UNDEF, UNDEF, UNDEF, 0.4, 0.3], out["temp"].to_a
  end

  def test_align_datetime_object_keys
    require "date"
    mk = ->(h, m) { DateTime.new(2023, 1, 26, h, m) }
    df = CAFrame.new(
      "time" => CA_OBJECT([mk[11, 40], mk[12, 20]]),
      "temp" => CA_FLOAT64([0.8, 0.3]),
    )
    ref = CA_OBJECT([mk[11, 40], mk[11, 50], mk[12, 20]])
    out = df.align("time", ref)
    assert_equal [0.8, UNDEF, 0.3], out["temp"].to_a
  end

  def test_align_nd_column_missing_row_fully_masked
    df = CAFrame.new(
      "time" => CA_INT64([700, 720]),
      "wind" => CA_FLOAT64([[1, 2], [3, 4]]),
    )
    out = df.align("time", CA_INT64([700, 710, 720]))
    assert_equal [1.0, 2.0], out["wind"][0, nil].to_a
    assert_equal UNDEF, out["wind"][1, 0]
    assert_equal UNDEF, out["wind"][1, 1]
    assert_equal [3.0, 4.0], out["wind"][2, nil].to_a
  end

  def test_align_accepts_array_reference
    out = @df.align("time", [700, 710, 720, 730, 740, 750, 760, 770])
    assert_equal 8, out.nrow
  end
end

class TestCAFramePaste < Test::Unit::TestCase
  def test_binds_columns_by_position
    a = CAFrame.new("s" => CA_OBJECT(%w[x y]), "temp" => CA_FLOAT64([1, 2]))
    b = CAFrame.new("rh" => CA_FLOAT64([40, 60]), "wind" => CA_FLOAT64([[1, 2], [3, 4]]))
    r = a.paste(b)
    assert_equal %w[s temp rh wind], r.variable_names
    assert_equal 2, r.nrow
    assert_equal [[1.0, 2.0], [3.0, 4.0]], r["wind"].to_a
  end

  def test_collision_suffixes_both_sides
    a = CAFrame.new("s" => CA_OBJECT(%w[x y]), "temp" => CA_FLOAT64([1, 2]))
    c = CAFrame.new("temp" => CA_FLOAT64([9, 8]), "p" => CA_FLOAT64([1, 2]))
    r = a.paste(c)
    assert_equal %w[s temp_left temp_right p], r.variable_names
    assert_equal [1.0, 2.0], r["temp_left"].to_a
    assert_equal [9.0, 8.0], r["temp_right"].to_a
  end

  def test_custom_suffixes_and_false
    a = CAFrame.new("temp" => CA_FLOAT64([1]))
    c = CAFrame.new("temp" => CA_FLOAT64([9]))
    assert_equal %w[temp_a temp_c], a.paste(c, suffixes: ["_a", "_c"]).variable_names
    assert_raise(ArgumentError) { a.paste(c, suffixes: false) }
  end

  def test_nrow_mismatch_raises
    a = CAFrame.new("t" => CA_FLOAT64([1, 2]))
    assert_raise(ArgumentError) { a.paste(CAFrame.new("z" => CA_INT32([1, 2, 3]))) }
  end

  def test_keeps_left_index_drops_other_index
    ai = CAFrame.new("v" => CA_FLOAT64([1, 2]), "t" => CA_INT64([10, 20])).set_index("t")
    bi = CAFrame.new("w" => CA_FLOAT64([3, 4]))
    ri = ai.paste(bi)
    assert_equal "t", ri.axis_name
    assert_equal [10, 20], ri.index.to_a
    assert_equal %w[v w], ri.variable_names
  end

  def test_non_frame_raises
    assert_raise(ArgumentError) { CAFrame.new("t" => CA_INT32([1])).paste([1]) }
  end

  # ---------- CAFrame.paste class method (N-ary symmetric) ----------

  def test_class_method_binds_three_frames
    a = CAFrame.new("s" => CA_OBJECT(%w[x y]))
    b = CAFrame.new("t" => CA_FLOAT64([1, 2]))
    c = CAFrame.new("u" => CA_INT32([10, 20]))
    r = CAFrame.paste(a, b, c)
    assert_equal %w[s t u], r.variable_names
    assert_equal 2, r.nrow
  end

  def test_class_method_accepts_array_argument
    a = CAFrame.new("s" => CA_OBJECT(%w[x y]))
    b = CAFrame.new("t" => CA_FLOAT64([1, 2]))
    r = CAFrame.paste([a, b])
    assert_equal %w[s t], r.variable_names
  end

  def test_class_method_three_frame_collision_needs_k_suffixes
    a = CAFrame.new("temp" => CA_FLOAT64([1, 2]))
    b = CAFrame.new("temp" => CA_FLOAT64([3, 4]))
    c = CAFrame.new("temp" => CA_FLOAT64([5, 6]))
    # Without a 3-element suffix list, DEFAULT (2-element) raises.
    assert_raise(ArgumentError) { CAFrame.paste(a, b, c) }
    r = CAFrame.paste(a, b, c, suffixes: ["_a", "_b", "_c"])
    assert_equal %w[temp_a temp_b temp_c], r.variable_names
  end

  def test_class_method_collision_free_no_suffixes_needed
    a = CAFrame.new("s" => CA_OBJECT(%w[x y]))
    b = CAFrame.new("t" => CA_FLOAT64([1, 2]))
    c = CAFrame.new("u" => CA_INT32([10, 20]))
    # Even without suffixes:, collision-free paste of 3 works with default.
    r = CAFrame.paste(a, b, c)
    assert_equal %w[s t u], r.variable_names
  end

  def test_class_method_nrow_mismatch_raises
    a = CAFrame.new("t" => CA_FLOAT64([1, 2]))
    b = CAFrame.new("z" => CA_INT32([1, 2, 3]))
    assert_raise(ArgumentError) { CAFrame.paste(a, b) }
  end

  def test_class_method_keeps_first_frame_index
    ai = CAFrame.new("v" => CA_FLOAT64([1, 2]), "t" => CA_INT64([10, 20])).set_index("t")
    bi = CAFrame.new("w" => CA_FLOAT64([3, 4]))
    ci = CAFrame.new("x" => CA_FLOAT64([5, 6]))
    r = CAFrame.paste(ai, bi, ci)
    assert_equal "t", r.axis_name
    assert_equal [10, 20], r.index.to_a
  end

  def test_class_method_empty_and_non_frame_raise
    assert_raise(ArgumentError) { CAFrame.paste }
    assert_raise(ArgumentError) { CAFrame.paste(CAFrame.new("t" => CA_INT32([1])), 42) }
  end

  def test_class_method_wrong_suffix_length_raises
    a = CAFrame.new("temp" => CA_FLOAT64([1]))
    b = CAFrame.new("temp" => CA_FLOAT64([2]))
    c = CAFrame.new("temp" => CA_FLOAT64([3]))
    # Suffix array length must match frame count when collision exists.
    assert_raise(ArgumentError) { CAFrame.paste(a, b, c, suffixes: ["_x", "_y"]) }
  end

  def test_class_method_result_shares_column_storage
    # paste is a view frame — writes to result columns propagate to inputs.
    a = CAFrame.new("t" => CA_FLOAT64([1, 2]))
    b = CAFrame.new("u" => CA_FLOAT64([3, 4]))
    r = CAFrame.paste(a, b)
    r["t"][0] = 99.0
    assert_equal 99.0, a["t"][0]
    r["u"][1] = 77.0
    assert_equal 77.0, b["u"][1]
  end
end

class TestCAFrameMeld < Test::Unit::TestCase
  # CAFrame.meld — view frame, strict same-dtype per column, writes propagate.

  def test_stacks_rows_matching_columns_by_name
    a = CAFrame.new("s" => CA_OBJECT(%w[x y]), "t" => CA_FLOAT64([1, 2]))
    b = CAFrame.new("t" => CA_FLOAT64([4, 5]), "s" => CA_OBJECT(%w[p q])) # order differs
    r = CAFrame.meld(a, b)
    assert_equal 4, r.nrow
    assert_equal %w[s t], r.variable_names
    assert_equal %w[x y p q], r["s"].to_a
    assert_equal [1.0, 2.0, 4.0, 5.0], r["t"].to_a
  end

  def test_dtype_mismatch_across_frames_raises
    # CAFrame.meld routes each column through CArray.meld — strict same-dtype.
    # Callers with mixed dtypes cast beforehand or use CAFrame.concatenate.
    a = CAFrame.new("t" => CA_FLOAT64([1, 2]))
    b = CAFrame.new("t" => CA_INT32([3]))
    assert_raise(ArgumentError) { CAFrame.meld(a, b) }
  end

  def test_preserves_mask
    a = CAFrame.new("t" => CA_FLOAT64([1, 2])); a["t"][1] = UNDEF
    b = CAFrame.new("t" => CA_FLOAT64([3]))
    assert_equal [false, true, false], CAFrame.meld(a, b)["t"].is_masked.to_a
  end

  def test_carries_nd_column
    u = CAFrame.new("w" => CA_FLOAT64([[1, 2], [3, 4]]))
    v = CAFrame.new("w" => CA_FLOAT64([[5, 6]]))
    assert_equal [[1.0, 2.0], [3.0, 4.0], [5.0, 6.0]], CAFrame.meld(u, v)["w"].to_a
  end

  def test_melds_index_when_all_indexed
    a = CAFrame.new("v" => CA_FLOAT64([1, 2]), "time" => CA_INT64([10, 20])).set_index("time")
    b = CAFrame.new("v" => CA_FLOAT64([3]), "time" => CA_INT64([30])).set_index("time")
    r = CAFrame.meld(a, b)
    assert_equal "time", r.axis_name
    assert_equal [10, 20, 30], r.index.to_a
    assert_equal [1.0, 2.0, 3.0], r["v"].to_a
  end

  def test_accepts_array_argument
    a = CAFrame.new("t" => CA_INT32([1]))
    b = CAFrame.new("t" => CA_INT32([2]))
    assert_equal [1, 2], CAFrame.meld([a, b])["t"].to_a
  end

  def test_single_frame_returns_view_sharing_input
    # N=1 meld returns a view frame sharing column storage with the input
    # (symmetric with N>=2 for the view-everywhere contract).
    a = CAFrame.new("t" => CA_FLOAT64([1, 2]))
    s = CAFrame.meld(a)
    assert_equal a["t"].to_a, s["t"].to_a
    s["t"][0] = 99.0
    assert_equal 99.0, a["t"][0]   # view semantic — write reaches parent
  end

  def test_column_set_mismatch_raises
    a = CAFrame.new("s" => CA_OBJECT(%w[x]), "t" => CA_FLOAT64([1]))
    b = CAFrame.new("s" => CA_OBJECT(%w[z]))
    assert_raise(ArgumentError) { CAFrame.meld(a, b) }
  end

  def test_index_mix_raises
    a = CAFrame.new("v" => CA_FLOAT64([1]), "time" => CA_INT64([10])).set_index("time")
    b = CAFrame.new("v" => CA_FLOAT64([2]))
    assert_raise(ArgumentError) { CAFrame.meld(a, b) }
  end

  def test_empty_and_non_frame_raise
    assert_raise(ArgumentError) { CAFrame.meld }
    assert_raise(ArgumentError) { CAFrame.meld(CAFrame.new("t" => CA_INT32([1])), "nope") }
  end
end

class TestCAFrameConcatenate < Test::Unit::TestCase
  # CAFrame.concatenate — eager frame, per-column auto-cast, independent result.

  def test_stacks_rows_matching_columns_by_name
    a = CAFrame.new("s" => CA_OBJECT(%w[x y]), "t" => CA_FLOAT64([1, 2]))
    b = CAFrame.new("t" => CA_INT32([4, 5]), "s" => CA_OBJECT(%w[p q]))   # int32 mix
    r = CAFrame.concatenate(a, b)
    assert_equal 4, r.nrow
    assert_equal %w[s t], r.variable_names
    assert_equal %w[x y p q], r["s"].to_a
    # per-column auto-cast: int32 + float64 → float64
    assert_equal [1.0, 2.0, 4.0, 5.0], r["t"].to_a
    assert_equal :float64, r["t"].data_type
  end

  def test_result_is_independent_of_inputs
    a = CAFrame.new("t" => CA_FLOAT64([1, 2]))
    b = CAFrame.new("t" => CA_FLOAT64([3, 4]))
    r = CAFrame.concatenate(a, b)
    r["t"][0] = 99.0
    # Eager: writes to result don't propagate to inputs.
    assert_equal 1.0, a["t"][0]
    assert_equal 3.0, b["t"][0]
  end

  def test_preserves_mask
    a = CAFrame.new("t" => CA_FLOAT64([1, 2])); a["t"][1] = UNDEF
    b = CAFrame.new("t" => CA_FLOAT64([3]))
    assert_equal [false, true, false], CAFrame.concatenate(a, b)["t"].is_masked.to_a
  end

  def test_concatenates_index_when_all_indexed
    a = CAFrame.new("v" => CA_FLOAT64([1, 2]), "time" => CA_INT64([10, 20])).set_index("time")
    b = CAFrame.new("v" => CA_FLOAT64([3]), "time" => CA_INT64([30])).set_index("time")
    r = CAFrame.concatenate(a, b)
    assert_equal "time", r.axis_name
    assert_equal [10, 20, 30], r.index.to_a
    assert_equal [1.0, 2.0, 3.0], r["v"].to_a
  end

  def test_accepts_array_argument
    a = CAFrame.new("t" => CA_INT32([1]))
    b = CAFrame.new("t" => CA_INT32([2]))
    assert_equal [1, 2], CAFrame.concatenate([a, b])["t"].to_a
  end

  def test_column_set_mismatch_raises
    a = CAFrame.new("s" => CA_OBJECT(%w[x]), "t" => CA_FLOAT64([1]))
    b = CAFrame.new("s" => CA_OBJECT(%w[z]))
    assert_raise(ArgumentError) { CAFrame.concatenate(a, b) }
  end

  def test_index_mix_raises
    a = CAFrame.new("v" => CA_FLOAT64([1]), "time" => CA_INT64([10])).set_index("time")
    b = CAFrame.new("v" => CA_FLOAT64([2]))
    assert_raise(ArgumentError) { CAFrame.concatenate(a, b) }
  end

  def test_empty_and_non_frame_raise
    assert_raise(ArgumentError) { CAFrame.concatenate }
    assert_raise(ArgumentError) { CAFrame.concatenate(CAFrame.new("t" => CA_INT32([1])), "nope") }
  end
end

class TestCAFrameSort < Test::Unit::TestCase
  def setup
    @df = CAFrame.new(
      "station" => CA_OBJECT(%w[tokyo osaka tokyo osaka]),
      "temp"    => CA_FLOAT64([22, 25, 19, 30]),
      "wind"    => CA_FLOAT64([[1, 2], [3, 4], [5, 6], [7, 8]]),
    )
  end

  def test_single_key_ascending
    s = @df.sort_by_key("temp")
    assert_equal [19.0, 22.0, 25.0, 30.0], s["temp"].to_a
    assert_equal %w[tokyo tokyo osaka osaka], s["station"].to_a
  end

  def test_multi_key_lexicographic
    m = @df.sort_by_key("station", "temp")
    assert_equal %w[osaka osaka tokyo tokyo], m["station"].to_a
    assert_equal [25.0, 30.0, 19.0, 22.0], m["temp"].to_a
  end

  def test_nd_column_rides_along
    m = @df.sort_by_key("station", "temp")
    assert_equal [[3.0, 4.0], [7.0, 8.0], [5.0, 6.0], [1.0, 2.0]], m["wind"].to_a
  end

  def test_returns_view_frame
    s = @df.sort_by_key("temp")
    assert_kind_of CAFrame, s
    refute_same @df["temp"], s["temp"]
  end

  def test_masked_key_rows_go_to_end
    dm = CAFrame.new("k" => CA_FLOAT64([3, 1, 2]), "v" => CA_OBJECT(%w[x y z]))
    dm["k"][0] = UNDEF
    sm = dm.sort_by_key("k")
    assert_equal [1.0, 2.0], sm["k"].to_a[0, 2]
    assert_equal UNDEF, sm["k"][2]
    assert_equal %w[y z x], sm["v"].to_a
  end

  def test_sort_by_datetime_index
    require "date"
    t = CArray.time(CA_OBJECT(%w[2024-03-01 2024-01-01 2024-02-01]), unit: :D)
    di = CAFrame.new("time" => t, "v" => CA_INT32([3, 1, 2])).set_index("time")
    si = di.sort_by_key("time")
    assert_equal [1, 2, 3], si["v"].to_a
  end

  def test_empty_missing_and_nd_key_raise
    assert_raise(ArgumentError) { @df.sort_by_key }
    assert_raise(KeyError)      { @df.sort_by_key("nope") }
    assert_raise(ArgumentError) { @df.sort_by_key("wind") } # N-D key
  end

  def test_sort_by_key_order_desc
    s = @df.sort_by_key("temp", order: :desc)
    assert_equal [30.0, 25.0, 22.0, 19.0], s["temp"].to_a
  end

  def test_sort_by_key_per_key_direction
    df = CAFrame.new("station" => CA_OBJECT(%w[z a m a]),
                     "temp"    => CA_FLOAT64([25, 25, 19, 30]))
    m = df.sort_by_key(["temp", :desc], ["station", :asc])
    assert_equal [30.0, 25.0, 25.0, 19.0], m["temp"].to_a
    assert_equal %w[a a z m], m["station"].to_a
  end

  def test_sort_by_key_blanket_order_over_multi_key
    m = @df.sort_by_key("station", "temp", order: :desc)
    assert_equal %w[tokyo tokyo osaka osaka], m["station"].to_a
    assert_equal [22.0, 19.0, 30.0, 25.0], m["temp"].to_a
  end

  def test_sort_by_key_mixed_bare_and_pair
    df = CAFrame.new("station" => CA_OBJECT(%w[z a m a]),
                     "temp"    => CA_FLOAT64([25, 25, 19, 30]))
    m = df.sort_by_key("station", ["temp", :desc]) # station asc, temp desc
    assert_equal %w[a a m z], m["station"].to_a
    assert_equal [30.0, 25.0, 19.0, 25.0], m["temp"].to_a
  end

  def test_sort_by_key_object_descending
    df = CAFrame.new("s" => CA_OBJECT(%w[b a b c]))
    assert_equal %w[c b b a], df.sort_by_key("s", order: :desc)["s"].to_a
  end

  def test_sort_by_key_masked_position
    df = CAFrame.new("k" => CA_FLOAT64([3, 1, 2]))
    df["k"][0] = UNDEF
    assert_equal UNDEF, df.sort_by_key("k")["k"][2]                       # last (default)
    assert_equal UNDEF, df.sort_by_key("k", masked_position: :first)["k"][0]
  end

  def test_sort_by_key_bad_order_and_spec_raise
    assert_raise(ArgumentError) { @df.sort_by_key("temp", order: :up) }
    assert_raise(ArgumentError) { @df.sort_by_key(["temp"]) }         # 1-element spec
    assert_raise(ArgumentError) { @df.sort_by_key(["temp", :up]) }    # bad per-key dir
  end

  def test_sort_by_block_masked_position
    df = CAFrame.new("k" => CA_FLOAT64([3, 1, 2]))
    df["k"][0] = UNDEF
    s = df.sort_by(masked_position: :first) { |f| f["k"] }
    assert_equal UNDEF, s["k"][0]
  end

  def test_sort_by_block_descending_via_dense_rank
    s = @df.sort_by { |f| f["temp"].order(descending: true, method: :dense) }
    assert_equal [30.0, 25.0, 22.0, 19.0], s["temp"].to_a
  end

  def test_sort_by_block_descending_object_key
    df = CAFrame.new("s" => CA_OBJECT(%w[b a b c]), "v" => CA_INT32([1, 2, 3, 4]))
    s = df.sort_by { |f| f["s"].order(descending: true, method: :dense) }
    assert_equal %w[c b b a], s["s"].to_a
  end

  def test_sort_by_block_multi_key_mixed_direction
    m = @df.sort_by { |f| [f["station"], f["temp"].order(descending: true, method: :dense)] }
    assert_equal %w[osaka osaka tokyo tokyo], m["station"].to_a
    assert_equal [30.0, 25.0, 22.0, 19.0], m["temp"].to_a
  end

  def test_sort_by_block_descending_ties_fall_through_to_next_key
    # temp descending with a tie (25 twice); station breaks the tie ascending.
    # A dense rank keeps the tie equal so the later key is consulted.
    df = CAFrame.new("station" => CA_OBJECT(%w[z a m a]),
                     "temp"    => CA_FLOAT64([25, 25, 19, 30]))
    m = df.sort_by { |f| [f["temp"].order(descending: true, method: :dense), f["station"]] }
    assert_equal [30.0, 25.0, 25.0, 19.0], m["temp"].to_a
    assert_equal %w[a a z m], m["station"].to_a
  end

  def test_sort_by_block_derived_key
    s = @df.sort_by { |f| (f["temp"] - 24).abs }
    assert_equal [25.0, 22.0, 19.0, 30.0], s["temp"].to_a
  end

  def test_sort_by_block_errors
    assert_raise(ArgumentError) { @df.sort_by }                       # no block
    assert_raise(ArgumentError) { @df.sort_by { |f| 42 } }            # non-CArray
    assert_raise(ArgumentError) { @df.sort_by { |f| CA_INT32([1,2]) } } # wrong length
    assert_raise(ArgumentError) { @df.sort_by { |f| [] } }            # empty
  end
end

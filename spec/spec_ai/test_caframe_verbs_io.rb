require "test/unit"
require "carray"
require "tempfile"

# CAFrame increments 2 (MEMO_DATAFRAME_ON_CARRAY.md):
#   from_csv (§11.2/§6-2), column verbs (§11.4), each_row/to_ca (§11.9/§11.11),
#   join_asof (§11.7).

class TestCAFrameFromCsv < Test::Unit::TestCase
  def with_csv(text)
    Tempfile.create(["obs", ".csv"]) do |f|
      f.write(text)
      f.flush
      yield f.path
    end
  end

  def test_headers_become_string_column_names
    with_csv("time,station,temp\n2024,tokyo,22.1\n") do |path|
      df = CAFrame.from_csv(path)
      assert_equal ["time", "station", "temp"], df.variable_names
      assert_equal 1, df.nrow
    end
  end

  def test_columns_read_raw_as_strings
    with_csv("temp\n22.1\n25.3\n") do |path|
      df = CAFrame.from_csv(path)
      assert_equal :object, df["temp"].data_type
      assert_equal ["22.1", "25.3"], df["temp"].to_a
    end
  end

  def test_types_hint_casts_with_parse_mask
    with_csv("temp,rh\n22.1,40\n,60\nxx,45\n") do |path|
      df = CAFrame.from_csv(path, types: { "temp" => :float64, "rh" => :int32 })
      assert_equal :float64, df["temp"].data_type
      # empty cell and "xx" fail to_type -> UNDEF (parse-mask, §6-2)
      assert_equal 22.1, df["temp"][0]
      assert_equal UNDEF, df["temp"][1]
      assert_equal UNDEF, df["temp"][2]
      assert_equal [40, 60, 45], df["rh"].to_a
    end
  end

  def test_rfc_spacing_preserved_by_default
    with_csv("a,b\nx , y\n") do |path|
      df = CAFrame.from_csv(path)
      assert_equal ["x "], df["a"].to_a
      assert_equal [" y"], df["b"].to_a
    end
  end

  def test_strip_trims_unquoted_fields
    with_csv("a,b\n x , y \n") do |path|
      df = CAFrame.from_csv(path, strip: true)
      assert_equal ["x"], df["a"].to_a
      assert_equal ["y"], df["b"].to_a
    end
  end

  def test_quoted_embedded_separator_newline_and_escape
    with_csv(%Q{x,note\n1,"a,b"\n2,"l1\nl2"\n3,"he said ""hi"""\n}) do |path|
      df = CAFrame.from_csv(path)
      assert_equal 3, df.nrow
      assert_equal ["a,b", "l1\nl2", %q{he said "hi"}], df["note"].to_a
    end
  end

  def test_empty_unquoted_is_nil_quoted_is_empty_string
    with_csv(%Q{a,b\np,\np,""\n}) do |path|
      df = CAFrame.from_csv(path)
      assert_equal [nil, ""], df["b"].to_a
    end
  end

  def test_ragged_short_row_padded_long_row_raises
    with_csv("a,b,c\n1,2\n1,2,3\n") do |path|
      df = CAFrame.from_csv(path)
      assert_equal 2, df.nrow
      assert_equal [nil, "3"], df["c"].to_a
    end
    with_csv("a,b\n1,2,3\n") do |path|
      assert_raise(ArgumentError) { CAFrame.from_csv(path) }
    end
  end

  def test_bom_stripped_from_first_header
    with_csv("\xEF\xBB\xBFname,x\nv,1\n") do |path|
      df = CAFrame.from_csv(path)
      assert_equal ["name", "x"], df.variable_names
    end
  end

  def test_columns_are_views_over_backing_array
    with_csv("a,b\n1,2\n3,4\n") do |path|
      df = CAFrame.from_csv(path)
      assert_kind_of CABlock, df["a"]
    end
  end

  def test_injected_parser
    with_csv("ignored\n") do |path|
      fake = ->(_p) { [["a", "b"], [["1", "2"], ["3", "4"]]] }
      df = CAFrame.from_csv(path, parser: fake)
      assert_equal ["a", "b"], df.variable_names
      assert_equal ["1", "3"], df["a"].to_a
    end
  end

  def test_dsl_skip_header_units_body
    with_csv("# note1\n# note2\nstation,temp\nname,degC\nTokyo,28.5\nOsaka,29.8\n") do |path|
      df = CAFrame.from_csv(path) do
        skip 2
        header
        skip 1
        body
      end
      assert_equal ["station", "temp"], df.variable_names
      assert_equal 2, df.nrow
      assert_equal ["28.5", "29.8"], df["temp"].to_a
    end
  end

  def test_dsl_column_names_headerless
    with_csv("Tokyo,28.5\nOsaka,29.8\n") do |path|
      df = CAFrame.from_csv(path) do
        column_names "station", "temp"
        body
      end
      assert_equal ["station", "temp"], df.variable_names
      assert_equal ["Tokyo", "Osaka"], df["station"].to_a
    end
  end

  def test_dsl_header_name_returns_secondary_header
    with_csv("station,temp\nname,degC\nTokyo,28.5\n") do |path|
      units = nil
      df = CAFrame.from_csv(path) do |csv|
        csv.header
        units = csv.header(:units)
        csv.body
      end
      assert_equal ["station", "temp"], df.variable_names
      assert_equal ["name", "degC"], units
      assert_equal ["Tokyo"], df["station"].to_a
    end
  end

  def test_dsl_generated_names_when_headerless
    with_csv("1,2,3\n4,5,6\n") do |path|
      df = CAFrame.from_csv(path) { body }
      assert_equal ["c0", "c1", "c2"], df.variable_names
      assert_equal ["1", "4"], df["c0"].to_a
    end
  end

  def test_dsl_with_types_cast
    with_csv("skip me\nstation,temp\nTokyo,28.5\nOsaka,x\n") do |path|
      df = CAFrame.from_csv(path, types: { "temp" => :float64 }) do
        skip 1
        header
        body
      end
      assert_equal 28.5, df["temp"][0]
      assert_equal UNDEF, df["temp"][1]
    end
  end
end

class TestCAFrameToCsv < Test::Unit::TestCase
  def setup
    @df = CAFrame.new(
      "station" => CA_OBJECT(["tokyo", "osa,ka", %q{ky"o}, ""]),
      "temp"    => CA_FLOAT64([22.1, 25.3, 19.0, 30.0]),
      "n"       => CA_INT32([1, 2, 3, 4]),
    )
    @df["temp"][2] = UNDEF
  end

  def test_string_form_without_path
    csv = @df.to_csv
    lines = csv.split("\n")
    assert_equal "station,temp,n", lines[0]
    assert_equal "tokyo,22.1,1", lines[1]
  end

  def test_separator_and_quote_escaping
    lines = @df.to_csv.split("\n")
    assert_equal %q{"osa,ka",25.3,2}, lines[2] # embedded separator quoted
    assert_equal %q{"ky""o",,3},      lines[3] # embedded quote doubled; masked -> empty
  end

  def test_masked_cell_is_empty_field
    assert_match(/,,/, @df.to_csv) # temp row 3 (UNDEF) between two commas
  end

  def test_empty_string_quoted_distinct_from_missing
    # genuine "" -> quoted "" (row 4 station), missing -> bare empty (temp row 3)
    lines = @df.to_csv.split("\n")
    assert_equal %q{"",30.0,4}, lines[4]
  end

  def test_header_false_omits_name_row
    assert_equal "tokyo,22.1,1", @df.to_csv(header: false).split("\n").first
  end

  def test_index_written_as_first_column
    lines = @df.set_index("station").to_csv.split("\n")
    assert_equal "station,temp,n", lines[0]
    assert_equal "tokyo,22.1,1", lines[1]
  end

  def test_index_false_omits_index_column
    assert_equal "temp,n", @df.set_index("station").to_csv(index: false).split("\n")[0]
  end

  def test_custom_separator
    df = CAFrame.new("a" => CA_INT32([1]), "b" => CA_OBJECT(["x;y"]))
    assert_equal %q{1;"x;y"}, df.to_csv(sep: ";").split("\n")[1]
  end

  def test_rejects_nd_column
    df = CAFrame.new("wind" => CA_FLOAT64([[1, 2], [3, 4]]))
    assert_raise(ArgumentError) { df.to_csv }
  end

  def test_write_to_path_returns_self
    Tempfile.create(["out", ".csv"]) do |f|
      assert_same @df, @df.to_csv(f.path)
      assert_equal @df.to_csv, File.read(f.path)
    end
  end

  def test_mask_and_empty_string_round_trip
    Tempfile.create(["rt", ".csv"]) do |f|
      @df.to_csv(f.path)
      back = CAFrame.from_csv(f.path, types: { "temp" => :float64, "n" => :int32 })
      assert_equal [22.1, 25.3, UNDEF, 30.0], back["temp"].to_a
      assert_equal [false, false, true, false], back["temp"].is_masked.to_a
      assert_equal ["tokyo", "osa,ka", %q{ky"o}, ""], back["station"].to_a
    end
  end

  def test_zero_rows_writes_header_only
    df = CAFrame.new("a" => CA_INT32([]), "b" => CA_FLOAT64([]))
    assert_equal "a,b\n", df.to_csv
    assert_equal "", df.to_csv(header: false)
  end
end

class TestCAFrameDatetimeVerbs < Test::Unit::TestCase
  def test_parse_across_string_column_types
    {
      "object"         => CA_OBJECT(%w[2024-06-15 2024-06-16]),
      "CAString"       => CArray.string(%w[2024-06-15 2024-06-16]),
      "CAConstString"  => CArray.const_string(%w[2024-06-15 2024-06-16]),
      "CAFixlenString" => CArray.fixlen_string(%w[2024-06-15 2024-06-16]),
    }.each do |label, col|
      df = CAFrame.new("t" => col)
      assert_same df, df.parse_to_time("t", unit: :D)
      assert_kind_of CATime, df["t"]
      assert_equal "2024-06-15", df["t"][0].to_s   # :D scalar prints date-only (unit-aware)
    end
  end

  def test_parse_rejects_non_string_column
    assert_raise(ArgumentError) do
      CAFrame.new("t" => CA_INT32([1, 2])).parse_to_time("t")
    end
  end

  def test_parse_chains_into_set_index
    df = CAFrame.new("time" => CA_OBJECT(%w[2024-01-01 2024-01-02]),
                     "x"    => CA_FLOAT64([1, 2]))
    g = df.parse_to_time("time").set_index("time")
    assert_equal "time", g.axis_name
    assert_kind_of CATime, g.index
    assert_equal "2024-01-01T00:00:00Z", g.index[0].to_s
  end

  def test_to_time_integer_unix_epoch
    df = CAFrame.new("t" => CA_INT64([0, 86_400]))
    df.to_time("t", unit: :s)
    assert_equal ["1970-01-01T00:00:00Z", "1970-01-02T00:00:00Z"],
                 df["t"].to_a.map(&:to_s)
  end

  def test_to_time_custom_epoch
    # netCDF-style "hours since 1990-01-01"
    df = CAFrame.new("t" => CA_INT64([0, 24, 48]))
    df.to_time("t", unit: :h, epoch: "1990-01-01")
    assert_equal ["1990-01-01T00:00:00Z", "1990-01-02T00:00:00Z",
                  "1990-01-03T00:00:00Z"], df["t"].to_a.map(&:to_s)
  end

  def test_to_time_whole_float_accepted
    df = CAFrame.new("t" => CA_FLOAT64([1.0, 2.0]))
    df.to_time("t", unit: :D, epoch: "1899-12-30") # Excel serial date
    assert_equal ["1899-12-31", "1900-01-01"],   # :D scalars print date-only
                 df["t"].to_a.map(&:to_s)
  end

  def test_to_time_fractional_float_rejected
    assert_raise(ArgumentError) do
      CAFrame.new("t" => CA_FLOAT64([1.5, 2.0])).to_time("t", unit: :D)
    end
  end

  def test_to_time_rejects_non_serial_column
    assert_raise(ArgumentError) do
      CAFrame.new("t" => CA_OBJECT(%w[a b])).to_time("t")
    end
  end

  def test_to_time_preserves_mask
    t = CA_INT64([0, 24, 48]); t[1] = UNDEF
    df = CAFrame.new("t" => t)
    df.to_time("t", unit: :h)
    assert_equal [false, true, false], df["t"].is_masked.to_a
  end

  def test_parse_preserves_mask_and_masks_unparseable
    # unparseable ("bad") and nil cells stay missing (parse-mask), not epoch
    df = CAFrame.new("t" => CA_OBJECT(["2024-01-01", "bad", "2024-01-03", nil]))
    df.parse_to_time("t", unit: :D)
    assert_equal [false, true, false, true], df["t"].is_masked.to_a
    assert_equal 1, df["t"].day[0]
  end

  def test_missing_column_raises
    df = CAFrame.new("t" => CA_OBJECT(%w[2024-01-01]))
    assert_raise(KeyError) { df.parse_to_time("nope") }
    assert_raise(KeyError) { df.to_time("nope") }
  end
end

class TestCAFrameColumnVerbs < Test::Unit::TestCase
  def setup
    @df = CAFrame.new("a" => CA_INT32([1, 2, 3]), "b" => CA_FLOAT64([10, 20, 30]))
  end

  def test_append_returns_new_frame
    r = @df.append("c", @df["a"] + @df["b"])
    assert_not_same @df, r
    assert_equal ["a", "b", "c"], r.variable_names
    assert_equal ["a", "b"], @df.variable_names   # original unchanged (§3.8)
    assert_equal [11.0, 22.0, 33.0], r["c"].to_a
  end

  def test_append_length_mismatch_raises
    assert_raise(ArgumentError) { @df.append("bad", CA_INT32([1, 2])) }
  end

  def test_append_to_empty_frame_adopts_length
    df = CAFrame.new
    r = df.append("x", CA_INT32([1, 2, 3, 4]))
    assert_equal 4, r.nrow
  end

  def test_drop_removes_columns
    r = @df.drop("b")
    assert_equal ["a"], r.variable_names
    assert_equal ["a", "b"], @df.variable_names   # original unchanged (§3.8)
  end

  def test_drop_missing_raises
    assert_raise(KeyError) { @df.drop("nope") }
  end

  def test_rename_preserves_order
    df = @df.append("c", CA_INT32([7, 8, 9]))
    r = df.rename("b" => "beta")
    assert_equal ["a", "beta", "c"], r.variable_names
    assert_equal [10.0, 20.0, 30.0], r["beta"].to_a
  end

  def test_rename_missing_raises
    assert_raise(KeyError) { @df.rename("nope" => "x") }
  end

  def test_rename_collision_raises
    assert_raise(ArgumentError) { @df.rename("a" => "b") }
  end

  def test_cast_rebinds_column
    @df.cast("a", :float64)
    assert_equal :float64, @df["a"].data_type
    assert_equal [1.0, 2.0, 3.0], @df["a"].to_a
  end

  def test_cast_string_column_parse_mask
    df = CAFrame.new("s" => CA_OBJECT(["1.5", "xx", "3"]))
    df.cast("s", :float64)
    assert_equal 1.5, df["s"][0]
    assert_equal UNDEF, df["s"][1]
    assert_equal 3.0, df["s"][2]
  end

  def test_cast_map_form
    r = @df.cast("a" => :float64, "b" => :int32)
    assert_same @df, r
    assert_equal :float64, @df["a"].data_type
    assert_equal :int32, @df["b"].data_type
  end

  def test_cast_array_key_shares_one_type
    @df.cast(["a", "b"] => :float64)
    assert_equal :float64, @df["a"].data_type
    assert_equal :float64, @df["b"].data_type
  end

  def test_cast_map_with_positional_type_raises
    assert_raise(ArgumentError) { @df.cast({ "a" => :float64 }, :int32) }
  end

  def test_cast_map_missing_column_raises
    assert_raise(KeyError) { @df.cast(["a", "nope"] => :float64) }
  end

  def test_mask_eq_numeric_in_place
    df = CAFrame.new("v" => CA_FLOAT64([1, -999, 3]))
    df.mask_eq("v", -999)
    assert_equal 1.0, df["v"][0]
    assert_equal UNDEF, df["v"][1]
  end

  def test_mask_eq_categorical_raises
    df = CAFrame.new("s" => CA_OBJECT(["a", "b", "a"]).categorize)
    assert_raise(RuntimeError) { df.mask_eq("s", df["s"][0]) }
  end

  # --- promote : one common data type for the whole frame ---------------

  def test_promote_without_target_picks_the_common_type
    df = CAFrame.new("x" => CA_FLOAT64([1, 2]), "y" => CA_INT32([3, 4]))
    assert_same df, df.promote
    assert_equal({ "x" => :float64, "y" => :float64 }, df.data_types)
  end

  def test_promote_makes_to_ca_writable
    df = CAFrame.new("x" => CA_FLOAT64([1, 2]), "y" => CA_INT32([3, 4]))
    assert_raise(RuntimeError) { df.to_ca(writable: true) }   # cast lane
    m = df.promote.to_ca(writable: true)
    m[0, 1] = 9.0
    assert_equal [9.0, 4.0], df["y"].to_a
  end

  def test_promote_leaves_a_uniform_frame_alone
    x = CA_FLOAT64([1, 2])
    df = CAFrame.new("x" => x, "y" => CA_FLOAT64([3, 4]))
    df.promote
    assert_same x, df["x"]
  end

  def test_promote_to_an_explicit_widening_type
    df = CAFrame.new("x" => CA_INT8([1, 2]), "y" => CA_INT32([3, 4]))
    df.promote(:float64)
    assert_equal({ "x" => :float64, "y" => :float64 }, df.data_types)
  end

  def test_promote_refuses_a_narrowing_target
    df = CAFrame.new("x" => CA_FLOAT64([1, 2]), "y" => CA_INT32([3, 4]))
    assert_raise(ArgumentError) { df.promote(:int32) }
  end

  def test_promote_rejects_a_class_target
    assert_raise(ArgumentError) { CAFrame.new("x" => CA_INT32([1, 2])).promote(CArray) }
  end

  def test_promote_object_admits_a_fixlen_column
    df = CAFrame.new("s" => CA_FIXLEN(["ab", "cd"], bytes: 2), "x" => CA_FLOAT64([1, 2]))
    assert_raise(RuntimeError) { df.to_ca }        # no common type as stored
    assert_equal [["ab", 1.0], ["cd", 2.0]], df.promote(:object).to_ca.to_a
  end

  def test_promote_object_takes_face_columns_through_their_surface
    df = CAFrame.new("s" => CArray.const_string(["ab", "cde"]),
                     "c" => CA_OBJECT(["p", "q"]).categorize,
                     "x" => CA_FLOAT64([1, 2]))
    df.promote(:object)
    assert_equal ["ab", "cde"], df["s"].to_a      # not the storage bytes
    assert_equal ["p", "q"], df["c"].to_a         # labels, not codes
    assert_equal [["ab", "p", 1.0], ["cde", "q", 2.0]], df.to_ca.to_a
  end

  def test_promote_keeps_a_uniformly_face_typed_frame_as_is
    t = CArray.time([0, 1], unit: :s)
    df = CAFrame.new("a" => t, "b" => t.copy)
    df.promote
    assert_kind_of CATime, df["a"]
    assert_kind_of CATime, df.to_ca
  end

  def test_promote_preserves_mask
    x = CA_FLOAT64([1, 2])
    x[1] = UNDEF
    df = CAFrame.new("x" => x).promote(:object)
    assert_equal UNDEF, df["x"][1]
  end

  def test_promote_of_a_face_and_numeric_mix_points_at_object
    df = CAFrame.new("t" => CArray.time([0, 1], unit: :s), "x" => CA_FLOAT64([1, 2]))
    e = assert_raise(ArgumentError) { df.promote }
    assert_match(/promote\(:object\)/, e.message)
  end

  # A Face column answers the cast for itself (core: #to_numeric for a numeric
  # target, the surface for :object), so the frame does not second-guess it.
  class ScaledInt < CAObject
    def initialize(parent, scale: 100)
      @scale = scale
      super(CA_FIXLEN, parent.dim, bytes: 8, storage: CA_INT64,
            parent: parent, face: true)
    end
    attr_reader :scale
    def copy_state(src); @scale = src.scale; end
    def storage_to_scalar(raw)
      (raw.is_a?(String) ? raw.unpack1("q") : raw) / @scale.to_f
    end
    def to_numeric; parent.float64 / @scale.to_f; end
  end

  def test_promote_to_a_numeric_type_uses_a_face_columns_declaration
    df = CAFrame.new("price" => ScaledInt.new(CA_INT64([12345, 13020])),
                     "qty"   => CA_FLOAT64([2, 1]))
    df.promote(:float64)
    assert_equal({ "price" => :float64, "qty" => :float64 }, df.data_types)
    assert_equal [[123.45, 2.0], [130.20, 1.0]], df.to_ca.to_a
  end

  def test_promote_of_a_face_column_that_declares_nothing_says_so
    df = CAFrame.new("t" => CArray.time([0, 1], unit: :s), "x" => CA_FLOAT64([1, 2]))
    e = assert_raise(TypeError) { df.promote(:float64) }
    assert_match(/to_numeric/, e.message)   # the core message, not a frame one
  end

  def test_promote_object_still_takes_a_face_columns_surface
    df = CAFrame.new("price" => ScaledInt.new(CA_INT64([12345, 13020])))
    assert_equal [123.45, 130.20], df.promote(:object)["price"].to_a
  end

  def test_promote_of_an_empty_frame_is_a_no_op
    df = CAFrame.new
    assert_same df, df.promote
    assert_equal 0, df.nvar
  end

  def test_cast_to_object_uses_a_face_columns_surface
    df = CAFrame.new("s" => CArray.const_string(["ab", "cde"]))
    df.cast("s", :object)
    assert_equal ["ab", "cde"], df["s"].to_a
  end

  def test_cast_of_a_face_column_to_a_storage_type_is_refused
    df = CAFrame.new("s" => CArray.const_string(["ab", "cde"]))
    e = assert_raise(TypeError) { df.cast("s", :fixlen) }
    assert_match(/to_numeric/, e.message)
  end

  def test_dup_does_not_share_the_columns_hash
    df = CAFrame.new("x" => CA_FLOAT64([1, 2]))
    other = df.dup
    other.cast("x", :int32)
    assert_equal :float64, df["x"].data_type
    assert_equal :int32, other["x"].data_type
  end

  def test_verbs_chain
    r = @df.append("c", CA_INT32([1, 2, 3])).cast("a", :float64).drop("b")
    assert_not_same @df, r
    assert_equal ["a", "c"], r.variable_names
    assert_equal ["a", "b"], @df.variable_names   # original unchanged (§3.8)
  end

  def test_verbs_touch_only_this_frames_membership
    # append returns a new frame; neither the receiver nor its parent changes (§3.8).
    view = @df[0..1]
    r = view.append("extra", CA_INT32([9, 9]))
    assert_equal ["a", "b", "extra"], r.variable_names
    assert_equal ["a", "b"], view.variable_names
    assert_equal ["a", "b"], @df.variable_names
  end
end

class TestCAFrameConvert < Test::Unit::TestCase
  def setup
    @df = CAFrame.new(
      "x"    => CA_FLOAT64([1, 2]),
      "y"    => CA_INT32([3, 4]),
      "wind" => CA_FLOAT64([[1, 2], [3, 4]]),
    )
  end

  def test_each_row_yields_hashes
    rows = []
    @df.each_row { |r| rows << r }
    assert_equal 2, rows.size
    assert_kind_of Hash, rows[0]
    assert_equal 1.0, rows[0]["x"]
    assert_equal [1.0, 2.0], rows[0]["wind"].to_a
  end

  def test_each_row_without_block_returns_enumerator
    e = @df.each_row
    assert_kind_of Enumerator, e
    assert_equal 2, e.to_a.size
  end

  # --- to_ca : (nrow, nvar) matrix view (memo §11.9) --------------------

  def test_to_ca_is_a_view_over_the_stored_columns
    df = CAFrame.new("x" => CA_FLOAT64([1, 2, 3]), "y" => CA_FLOAT64([4, 5, 6]))
    m = df.to_ca
    assert_kind_of CAStack, m
    assert_equal [3, 2], m.shape
    assert_equal [[1.0, 4.0], [2.0, 5.0], [3.0, 6.0]], m.to_a
    m[0, 1] = 99.0                       # writes flow back to the column
    assert_equal [99.0, 5.0, 6.0], df["y"].to_a
  end

  def test_to_ca_copy_is_independent
    df = CAFrame.new("x" => CA_FLOAT64([1, 2, 3]), "y" => CA_FLOAT64([4, 5, 6]))
    owned = df.to_ca.copy
    owned[0, 0] = -1.0
    assert_equal [1.0, 2.0, 3.0], df["x"].to_a
  end

  def test_to_ca_promotes_mixed_data_types
    df = CAFrame.new("x" => CA_FLOAT64([1, 2, 3]), "y" => CA_INT32([4, 5, 6]))
    m = df.to_ca
    assert_equal :float64, m.data_type
    assert_equal [[1.0, 4.0], [2.0, 5.0], [3.0, 6.0]], m.to_a
  end

  def test_to_ca_column_order_follows_the_columns_hash
    df = CAFrame.new("b" => CA_INT32([1, 2]), "a" => CA_INT32([3, 4]))
    assert_equal [[1, 3], [2, 4]], df.to_ca.to_a
  end

  def test_to_ca_preserves_mask
    x = CA_FLOAT64([1, 2, 3])
    x[1] = UNDEF
    df = CAFrame.new("x" => x, "y" => CA_FLOAT64([4, 5, 6]))
    m = df.to_ca
    assert_equal UNDEF, m[1, 0]
    assert_equal 5.0, m[1, 1]
  end

  def test_to_ca_rejects_nd_columns
    assert_raise(ArgumentError) { @df.to_ca }
  end

  def test_to_ca_rejects_empty_frame
    assert_raise(ArgumentError) { CAFrame.new.to_ca }
  end

  def test_to_ca_writable_passes_when_columns_are_shared
    df = CAFrame.new("x" => CA_FLOAT64([1, 2, 3]), "y" => CA_FLOAT64([4, 5, 6]))
    m = df.to_ca(writable: true)
    m[2, 0] = 7.0
    assert_equal [1.0, 2.0, 7.0], df["x"].to_a
  end

  def test_to_ca_writable_refused_when_a_column_is_promoted
    df = CAFrame.new("x" => CA_FLOAT64([1, 2, 3]), "y" => CA_INT32([4, 5, 6]))
    assert_nothing_raised { df.to_ca }
    assert_raise(RuntimeError) { df.to_ca(writable: true) }
  end

  def test_to_ca_writable_refused_when_a_column_is_read_only
    ro = CA_FLOAT64([4, 5, 6])
    ro.set_read_only_flag
    df = CAFrame.new("x" => CA_FLOAT64([1, 2, 3]), "y" => ro)
    assert_raise(RuntimeError) { df.to_ca(writable: true) }
  end

  def test_wrap_writable_accepts_a_frame_with_shared_columns
    df = CAFrame.new("x" => CA_FLOAT64([1, 2, 3]), "y" => CA_FLOAT64([4, 5, 6]))
    w = CArray.wrap_writable(df)
    w[0, 0] = 8.0
    assert_equal [8.0, 2.0, 3.0], df["x"].to_a
  end
end

class TestCAFrameJoinAsof < Test::Unit::TestCase
  def setup
    @obs = CAFrame.new("time" => CA_INT64([10, 20, 30, 40]), "t" => CA_FLOAT64([1, 2, 3, 4]))
    @radar = CAFrame.new("time" => CA_INT64([12, 25]), "dbz" => CA_FLOAT64([50, 60]))
  end

  def test_asof_is_row_preserving
    j = @obs.join_asof(@radar, on: "time")
    assert_equal 4, j.nrow
    assert_equal ["time", "t", "dbz"], j.variable_names
    assert_equal [10, 20, 30, 40], j["time"].to_a
  end

  def test_asof_floor_matches_at_or_before_within_range
    j = @obs.join_asof(@radar, on: "time", direction: :floor)
    # 20 -> radar 12 (dbz 50); 10 below range, 30/40 beyond range -> UNDEF
    assert_equal UNDEF, j["dbz"][0]
    assert_equal 50.0, j["dbz"][1]
    assert_equal UNDEF, j["dbz"][2]
    assert_equal UNDEF, j["dbz"][3]
  end

  def test_asof_tolerance_masks_far_matches
    j = @obs.join_asof(@radar, on: "time", direction: :floor, tolerance: 3)
    # 20 -> 12 is distance 8 > 3 -> UNDEF
    assert_equal UNDEF, j["dbz"][1]
  end

  def test_asof_ceil_direction
    j = @obs.join_asof(@radar, on: "time", direction: :ceil)
    # 20 -> radar 25 (dbz 60)
    assert_equal 60.0, j["dbz"][1]
  end
end

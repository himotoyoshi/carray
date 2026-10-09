require "test/unit"
require "stringio"
require "carray"

# CAFrame.from_csv gives its text columns as CAString, so the string
# operations work on the columns themselves.
class TestCAFrameCSVTextColumns < Test::Unit::TestCase
  CSV = "station,code,temp\n  Tokyo ,A-12,22.1\nOsaka,B-7,\n,C-x,19.5\n"

  def frame(**opts)
    CAFrame.from_csv(StringIO.new(CSV), **opts)
  end

  def test_text_columns_are_castring
    df = frame
    assert_equal [CAString] * 3, df.columns.map(&:class)
    assert_equal({ "station" => :object, "code" => :object, "temp" => :object }, df.data_types)
    assert_equal ["  Tokyo ", "Osaka", UNDEF], df["station"].to_a
  end

  def test_in_place_operations_write_to_the_frame
    df = frame
    df["station"].strip!
    df["code"].gsub!("-", "")
    assert_equal ["Tokyo", "Osaka", UNDEF], df["station"].to_a
    assert_equal ["A12", "B7", "Cx"], df["code"].to_a
    assert_equal ["22.1", UNDEF, "19.5"], df["temp"].to_a
  end

  def test_a_view_frame_writes_through_too
    df = frame
    df.head(1)["station"].strip!
    assert_equal ["Tokyo", "Osaka", UNDEF], df["station"].to_a
  end

  def test_extract_then_cast
    df = frame
    df["num"] = df["code"].extract(/(\d+)/, '\1')
    df.cast("num", :int32)
    assert_equal [12, 7, UNDEF], df["num"].to_a
  end

  def test_infer_types_looks_at_castring_columns
    assert_equal({ "temp" => :float64 }, frame.infer_types)
    assert_equal :float64, frame(types: :infer)["temp"].data_type
  end

  def test_a_castring_key_joins_an_object_key
    other = CAFrame.new("code" => CA_OBJECT(["B-7", "A-12"]), "n" => CA_INT32([2, 1]))
    assert_equal [1, 2, UNDEF], frame.join(other, on: "code")["n"].to_a
  end

  def test_round_trips_through_to_csv
    df = frame
    back = CAFrame.from_csv(StringIO.new(df.to_csv))
    df.column_names.each { |n| assert_equal df[n].to_a, back[n].to_a, n }
  end

  # A cell extract does not match used to become "", which cast read as 0.
  def test_extract_masks_a_cell_that_does_not_match
    assert_equal ["12", "7", UNDEF], frame["code"].extract(/(\d+)/, '\1').to_a
    assert_equal [""], CArray.string(["ab"]).extract(/x*/).to_a
  end

  def test_split_column
    df = CAFrame.from_csv(StringIO.new("id,code,v\n1,A-12,x\n2,B-7-x,y\n3,C,z\n4,,w\n"))
    s = df.split_column("code", "-", into: ["kind", "num"])
    assert_equal ["id", "kind", "num", "v"], s.column_names
    assert_equal ["A", "B", "C", UNDEF], s["kind"].to_a
    assert_equal ["12", "7-x", UNDEF, UNDEF], s["num"].to_a   # the rest stays in the last
    assert_equal [CAString, CAString], [s["kind"].class, s["num"].class]
    assert_equal ["id", "code", "v"], df.column_names
    assert_equal [12, UNDEF, UNDEF, UNDEF], s.cast("num", :int32)["num"].to_a
  end

  def test_split_column_at_a_regexp
    df = CAFrame.new("c" => CA_OBJECT(["a_b-c", "d"]))
    s = df.split_column("c", /[-_]/, into: %w[x y z])
    assert_equal [["a", "d"], ["b", UNDEF], ["c", UNDEF]], s.columns.map(&:to_a)
  end

  def test_split_column_keeps_the_index
    df = frame.set_index("station")
    assert_equal df.index.to_a, df.split_column("code", "-", into: %w[k n]).index.to_a
  end

  def test_split_column_refuses
    df = frame
    assert_raise(ArgumentError) { df.split_column("code", "-", into: ["a"]) }
    assert_raise(ArgumentError) { df.split_column("code", "-", into: ["a", "a"]) }
    assert_raise(ArgumentError) { df.split_column("code", "-", into: ["temp", "x"]) }
    assert_raise(ArgumentError) { df.split_column("code", 1, into: ["a", "b"]) }
    assert_raise(KeyError) { df.split_column("nope", "-", into: ["a", "b"]) }
    assert_raise(ArgumentError) do
      CAFrame.new("n" => CA_INT32([1])).split_column("n", "-", into: ["a", "b"])
    end
  end

  def test_a_file_with_no_rows
    df = CAFrame.from_csv(StringIO.new("a,b\n"))
    assert_equal [CAString, CAString], df.columns.map(&:class)
    assert_equal 0, df.nrow
  end
end

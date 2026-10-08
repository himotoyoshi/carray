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
    assert_equal [CAString] * 3, df.variables.map(&:class)
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
    df.variable_names.each { |n| assert_equal df[n].to_a, back[n].to_a, n }
  end

  def test_a_file_with_no_rows
    df = CAFrame.from_csv(StringIO.new("a,b\n"))
    assert_equal [CAString, CAString], df.variables.map(&:class)
    assert_equal 0, df.nrow
  end
end

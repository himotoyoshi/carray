require "test/unit"
require "stringio"
require "carray"

# CAFrame.from_csv(missing:) / CAFrame#to_csv(missing:): a file's own
# spelling of a missing value.

class TestCAFrameCSVMissing < Test::Unit::TestCase
  CSV = "time,temp,rh\n1,20.5,-999\n2,-999,///\n3,///,40\n"

  def read(**opts)
    CAFrame.from_csv(StringIO.new(CSV), **opts)
  end

  def test_tokens_mask_every_column
    df = read(missing: ["-999", "///"])
    assert_equal ["20.5", UNDEF, UNDEF], df["temp"].to_a
    assert_equal [UNDEF, UNDEF, "40"], df["rh"].to_a
    assert_equal ["1", "2", "3"], df["time"].to_a
  end

  def test_a_single_token_string
    df = read(missing: "-999")
    assert_equal ["20.5", UNDEF, "///"], df["temp"].to_a
  end

  def test_tokens_per_column
    df = read(missing: { "temp" => "-999", "rh" => ["-999", "///"] })
    assert_equal ["20.5", UNDEF, "///"], df["temp"].to_a
    assert_equal [UNDEF, UNDEF, "40"], df["rh"].to_a
  end

  def test_masks_before_types_cast
    df = read(missing: ["-999", "///"], types: { "temp" => :float64, "rh" => :int32 })
    assert_equal [20.5, UNDEF, UNDEF], df["temp"].to_a
    assert_equal [UNDEF, UNDEF, 40], df["rh"].to_a
  end

  def test_without_missing_a_sentinel_is_a_number
    df = read(types: { "temp" => :float64 })
    assert_equal -999.0, df["temp"][1]
  end

  def test_tokens_match_the_text_exactly
    df = CAFrame.from_csv(StringIO.new("v\n-999\n-999.0\n\"-999\"\n"), missing: "-999")
    assert_equal [UNDEF, "-999.0", UNDEF], df["v"].to_a
  end

  def test_tokens_match_after_strip
    df = CAFrame.from_csv(StringIO.new("v\n -999 \n1\n"), missing: "-999", strip: true)
    assert_equal [UNDEF, "1"], df["v"].to_a
  end

  def test_the_empty_field_stays_missing
    df = CAFrame.from_csv(StringIO.new("a,b\n1,\n,x\n"), missing: "x")
    assert_equal ["1", UNDEF], df["a"].to_a
    assert_equal [UNDEF, UNDEF], df["b"].to_a
  end

  def test_non_string_tokens_raise
    err = assert_raise(ArgumentError) { read(missing: -999) }
    assert_match(/"-999", not -999/, err.message)
  end

  def test_an_unknown_column_raises
    assert_raise(KeyError) { read(missing: { "nope" => "-999" }) }
  end

  def test_works_with_the_reading_dsl
    text = "# station A\ntime,temp\n1,-999\n"
    df = CAFrame.from_csv(StringIO.new(text), missing: "-999") { skip 1; header; body }
    assert_equal [UNDEF], df["temp"].to_a
  end
end

class TestCAFrameToCSVMissing < Test::Unit::TestCase
  def setup
    temp = CA_FLOAT64([20.5, 0.0, 30.0])
    temp[1] = UNDEF
    @df = CAFrame.new("time" => CA_INT32([1, 2, 3]), "temp" => temp)
  end

  def test_writes_the_token_for_a_masked_cell
    assert_equal "time,temp\n1,20.5\n2,-999\n3,30.0\n", @df.to_csv(missing: "-999")
  end

  def test_default_is_still_the_empty_field
    assert_equal "time,temp\n1,20.5\n2,\n3,30.0\n", @df.to_csv
  end

  def test_round_trips_with_from_csv
    csv = @df.to_csv(missing: "NA")
    back = CAFrame.from_csv(StringIO.new(csv), missing: "NA", types: { "temp" => :float64 })
    assert_equal [20.5, UNDEF, 30.0], back["temp"].to_a
  end

  def test_a_masked_index_cell_gets_the_token
    idx = CA_INT32([1, 2, 3])
    idx[2] = UNDEF
    df = CAFrame.new({ "v" => CA_INT32([4, 5, 6]) }, index: idx, axis_name: "t")
    assert_equal "t,v\n1,4\n2,5\n-,6\n", df.to_csv(missing: "-")
  end

  def test_a_value_written_as_the_token_raises
    @df["temp"][2] = -999.0
    err = assert_raise(ArgumentError) { @df.to_csv(missing: "-999.0") }
    assert_match(/row 2 of "temp"/, err.message)
  end

  def test_a_token_needing_quotes_is_quoted
    assert_equal "time,temp\n1,20.5\n2,\"n,a\"\n3,30.0\n", @df.to_csv(missing: "n,a")
  end

  def test_non_string_missing_raises
    assert_raise(ArgumentError) { @df.to_csv(missing: -999) }
  end
end

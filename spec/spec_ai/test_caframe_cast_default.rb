require "test/unit"
require "carray"
require "stringio"

# CAFrame#cast takes :infer and a map with default: -- the shapes from_csv /
# from_records' types: takes -- and an error about the map names the option
# it came in through.
class TestCAFrameCastDefault < Test::Unit::TestCase
  CSV_TEXT = <<~CSV
    station,code,temp,count,id
    tokyo,007,22.1,3,10
    osaka,012,,4,11
    nagoya,105,21.0,,12
  CSV

  def frame
    CAFrame.from_csv(StringIO.new(CSV_TEXT))
  end

  def test_infer
    df = frame
    assert_same df, df.cast(:infer)
    assert_equal :float64, df["temp"].data_type
    assert_equal :int64, df["count"].data_type
    assert_equal :int64, df["id"].data_type
    assert_equal :object, df["station"].data_type
    assert_equal :object, df["code"].data_type     # leading zero = a code
  end

  def test_infer_matches_infer_types
    a = frame.cast(:infer)
    b = frame
    b.cast(b.infer_types)
    assert_equal b.data_types, a.data_types
  end

  def test_infer_takes_on_error
    df = frame
    df.cast(:infer, on_error: :warn)
    assert_equal :float64, df["temp"].data_type
  end

  def test_default_infer_with_named_columns
    df = frame.cast(default: :infer, "code" => :int32, "id" => nil)
    assert_equal :int32, df["code"].data_type
    assert_equal [7, 12, 105], df["code"].to_a
    assert_equal :object, df["id"].data_type
    assert_equal ["10", "11", "12"], df["id"].to_a
    assert_equal :float64, df["temp"].data_type
    assert_equal :int64, df["count"].data_type
  end

  def test_default_type_casts_every_column_not_named
    df = frame.cast(default: :float64, "station" => nil, "code" => nil)
    assert_equal :object, df["station"].data_type
    assert_equal :object, df["code"].data_type
    assert_equal [22.1, UNDEF, 21.0], df["temp"].to_a
    assert_equal [3.0, 4.0, UNDEF], df["count"].to_a
    assert_equal :float64, df["id"].data_type
  end

  def test_default_type_alone
    df = CAFrame.new("a" => CA_INT32([1, 2]), "b" => CA_INT16([3, 4]))
    df.cast(default: :float64)
    assert_equal [:float64, :float64], df.column_names.map { |n| df[n].data_type }
  end

  def test_a_map_given_positionally
    df = frame.cast({ default: :float64, "station" => nil, "code" => nil })
    assert_equal :float64, df["temp"].data_type
    assert_equal :object, df["station"].data_type
  end

  def test_a_named_column_replaces_the_default
    df = frame.cast(default: :float64, "count" => :int32, "station" => nil, "code" => nil)
    assert_equal :int32, df["count"].data_type
    assert_equal :float64, df["id"].data_type
  end

  def test_nil_leaves_a_named_column_as_it_is
    df = frame.cast("temp" => nil, "count" => :int64)
    assert_equal :object, df["temp"].data_type
    assert_equal :int64, df["count"].data_type
  end

  def test_an_array_key_with_nil
    df = frame.cast(default: :infer, ["code", "id"] => nil)
    assert_equal :object, df["code"].data_type
    assert_equal :object, df["id"].data_type
    assert_equal :float64, df["temp"].data_type
  end

  def test_an_unknown_column_raises_keyerror_naming_cast
    df = frame
    err = assert_raise(KeyError) { df.cast(default: :infer, "nope" => :int32) }
    assert_match(/\Acast /, err.message)
    assert_match(/"nope"/, err.message)
    assert_equal :object, df["temp"].data_type
  end

  def test_an_unknown_column_with_nil_raises_too
    assert_raise(KeyError) { frame.cast("nope" => nil) }
  end

  def test_a_symbol_key_other_than_default_raises
    df = frame
    err = assert_raise(ArgumentError) { df.cast(defualt: :infer) }
    assert_match(/\Acast /, err.message)
    assert_match(/:default/, err.message)
    assert_match(/:defualt/, err.message)
    err = assert_raise(ArgumentError) { df.cast({ temp: :float64 }) }
    assert_match(/:temp/, err.message)
  end

  def test_a_raise_leaves_the_frame_as_it_was
    df = frame
    before = df.column_names.to_h { |n| [n, df[n]] }
    assert_raise(CAFrame::UnreadableColumn) do
      df.cast({ default: :float64 }, on_error: :raise)    # "tokyo" does not read
    end
    df.column_names.each { |n| assert_same before[n], df[n] }
  end

  def test_three_existing_shapes
    df = frame.cast("temp", :float64)
    assert_equal :float64, df["temp"].data_type
    df = frame.cast("temp" => :float64, "count" => :int32)
    assert_equal :int32, df["count"].data_type
    df = frame.cast(["temp", "count"] => :float64)
    assert_equal :float64, df["count"].data_type
    df = frame.cast("temp" => :float64, on_error: :warn)
    assert_equal :float64, df["temp"].data_type
  end

  def test_option_name_names_the_option
    df = frame
    err = assert_raise(ArgumentError) { df.cast("bad", option_name: :types) }
    assert_match(/\Atypes: takes a map of column types or :infer/, err.message)
    err = assert_raise(KeyError) { df.cast({ "nope" => :int32 }, option_name: :types) }
    assert_match(/\Atypes: /, err.message)
    err = assert_raise(ArgumentError) { df.cast({ defualt: :infer }, option_name: :types) }
    assert_match(/\Atypes: /, err.message)
  end

  def test_from_csv_errors_name_types
    err = assert_raise(ArgumentError) { CAFrame.from_csv(StringIO.new(CSV_TEXT), types: "bad") }
    assert_match(/\Atypes: takes a map of column types or :infer/, err.message)
    err = assert_raise(KeyError) do
      CAFrame.from_csv(StringIO.new(CSV_TEXT), types: { "nope" => :int32 })
    end
    assert_match(/\Atypes: /, err.message)
    err = assert_raise(ArgumentError) do
      CAFrame.from_csv(StringIO.new(CSV_TEXT), types: { defualt: :infer })
    end
    assert_match(/\Atypes: /, err.message)
  end

  def test_from_records_errors_name_types
    recs = [{ "a" => "1" }, { "a" => "2" }]
    err = assert_raise(ArgumentError) { CAFrame.from_records(recs, types: :float64) }
    assert_match(/\Atypes: takes a map/, err.message)
  end
end

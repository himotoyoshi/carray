require "test/unit"
require "carray"
require "stringio"

# from_csv / from_records types: with :default -- the columns the map does
# not name take the default (:infer or a type), a named column takes its own
# entry, and nil leaves it as it was read.
class TestCAFrameTypesDefault < Test::Unit::TestCase
  CSV_TEXT = <<~CSV
    station,code,temp,count,id
    tokyo,007,22.1,3,10
    osaka,012,,4,11
    nagoya,105,21.0,,12
  CSV

  def frame(**opts)
    CAFrame.from_csv(StringIO.new(CSV_TEXT), **opts)
  end

  def test_infer_with_a_column_set_by_hand
    df = frame(types: { default: :infer, "code" => :int32 })
    assert_equal :int32, df["code"].data_type
    assert_equal [7, 12, 105], df["code"].to_a
    assert_equal :float64, df["temp"].data_type
    assert_equal :int64, df["count"].data_type
    assert_equal :object, df["station"].data_type
  end

  def test_nil_keeps_a_column_out_of_inference
    df = frame(types: { default: :infer, "id" => nil })
    assert_equal :object, df["id"].data_type
    assert_equal ["10", "11", "12"], df["id"].to_a
    assert_equal :int64, df["count"].data_type
  end

  def test_infer_default_matches_types_infer
    a = frame(types: :infer)
    b = frame(types: { default: :infer })
    assert_equal a.data_types, b.data_types
  end

  def test_a_type_default_casts_every_column_not_named
    df = frame(types: { default: :float64, "station" => nil, "code" => nil })
    assert_equal :object, df["station"].data_type
    assert_equal :object, df["code"].data_type
    assert_equal [22.1, UNDEF, 21.0], df["temp"].to_a
    assert_equal [3.0, 4.0, UNDEF], df["count"].to_a
    assert_equal :float64, df["id"].data_type
  end

  def test_an_array_key_names_several_columns
    df = frame(types: { default: :infer, ["code", "id"] => nil })
    assert_equal :object, df["code"].data_type
    assert_equal :object, df["id"].data_type
    assert_equal :float64, df["temp"].data_type
  end

  def test_a_map_without_default_still_casts_only_what_it_names
    df = frame(types: { "temp" => :float64, "id" => nil })
    assert_equal :float64, df["temp"].data_type
    assert_equal :object, df["count"].data_type
    assert_equal :object, df["id"].data_type
  end

  def test_on_error_applies_to_the_default_too
    assert_raise(ArgumentError) do
      frame(types: { default: :float64 }, on_error: :raise)   # "tokyo" does not read
    end
  end

  def test_a_symbol_other_than_default_raises
    err = assert_raise(ArgumentError) { frame(types: { defualt: :infer }) }
    assert_match(/:default/, err.message)
  end

  def test_an_unknown_column_raises
    assert_raise(KeyError) { frame(types: { default: :infer, "nope" => :int32 }) }
  end

  def test_runs_after_missing_tokens
    text = "a,b\n1,-999\n2,3\n"
    df = CAFrame.from_csv(StringIO.new(text), missing: "-999",
                          types: { default: :infer, "a" => nil })
    assert_equal :int64, df["b"].data_type
    assert_equal [UNDEF, 3], df["b"].to_a
    assert_equal :object, df["a"].data_type
  end

  def test_from_records
    recs = [{ "a" => "1", "b" => "x", "c" => 2 }, { "a" => "2", "b" => "y", "c" => 3 }]
    df = CAFrame.from_records(recs, types: { default: :infer, "a" => nil })
    assert_equal :object, df["a"].data_type
    assert_equal :object, df["b"].data_type
    df = CAFrame.from_records(recs, types: { default: :float64, "b" => nil })
    assert_equal :float64, df["a"].data_type
    assert_equal [2.0, 3.0], df["c"].to_a
  end
end

require "test/unit"
require "carray"
require "date"

# CAFrame.from_records (memo §11.2 records input, §11.5 N-D columns):
#   row Hashes -> columns, native leaf typing, N-D array cells, mask-not-promote.

class TestCAFrameFromRecords < Test::Unit::TestCase
  def test_native_leaf_typing
    recs = [
      { "pref" => 54, "pressure" => 1018.0, "name" => "a" },
      { "pref" => 55, "pressure" => 1017.9, "name" => "b" },
    ]
    df = CAFrame.from_records(recs)
    assert_equal :int64, df["pref"].data_type       # all Integer -> int64
    assert_equal :float64, df["pressure"].data_type  # all Float -> float64
    assert_equal :object, df["name"].data_type       # strings -> object
    assert_equal [54, 55], df["pref"].to_a
  end

  def test_int_with_missing_stays_int_with_undef
    recs = [{ "h" => 53 }, { "h" => nil }, { "h" => 56 }]
    df = CAFrame.from_records(recs)
    assert_equal :int64, df["h"].data_type           # not promoted to float
    assert_equal 53, df["h"][0]
    assert_equal UNDEF, df["h"][1]
    assert_equal 56, df["h"][2]
  end

  def test_missing_key_is_union_and_nil
    recs = [{ "a" => 1, "b" => 2 }, { "a" => 3 }]
    df = CAFrame.from_records(recs)
    assert_equal ["a", "b"], df.variable_names            # union, first-appearance order
    assert_equal 2, df["b"][0]
    assert_equal UNDEF, df["b"][1]                   # missing -> UNDEF
  end

  def test_int_float_mix_consolidates_to_float
    recs = [{ "x" => 1 }, { "x" => 2.5 }]
    df = CAFrame.from_records(recs)
    assert_equal :float64, df["x"].data_type
    assert_equal [1.0, 2.5], df["x"].to_a
  end

  def test_nd_column_from_equal_length_arrays
    recs = [
      { "temp" => [21, 25, 29], "p" => 1018.0 },
      { "temp" => [20, 24, 30], "p" => 1017.9 },
    ]
    df = CAFrame.from_records(recs)
    assert_equal [2, 3], df["temp"].shape
    assert_equal :int64, df["temp"].data_type
    assert_equal [21, 20], df["temp"][nil, 0].to_a   # min component
    assert_equal [29, 30], df["temp"][nil, 2].to_a   # max component
    assert_equal [2], df["p"].shape                   # scalar column stays 1-D
  end

  def test_nd_column_float_leaves
    recs = [{ "v" => [1, 2.5] }, { "v" => [3, 4.0] }]
    df = CAFrame.from_records(recs)
    assert_equal :float64, df["v"].data_type
    assert_equal [2, 2], df["v"].shape
  end

  def test_ragged_arrays_fall_back_to_object
    recs = [{ "v" => [1, 2] }, { "v" => [1, 2, 3] }]
    df = CAFrame.from_records(recs)
    assert_equal :object, df["v"].data_type
    assert_equal 1, df["v"].ndim
  end

  def test_datetime_and_time_strings_stay_object
    recs = [
      { "time" => DateTime.parse("2023-01-26T02:40:00+00:00"), "maxTempTime" => "17:40" },
      { "time" => DateTime.parse("2023-01-26T02:50:00+00:00"), "maxTempTime" => "17:46" },
    ]
    df = CAFrame.from_records(recs)
    assert_equal :object, df["time"].data_type        # no date-like parsing
    assert_equal :object, df["maxTempTime"].data_type
  end

  def test_types_override
    recs = [{ "pref" => 54 }, { "pref" => 55 }]
    df = CAFrame.from_records(recs, types: { "pref" => :int32 })
    assert_equal :int32, df["pref"].data_type
  end

  def test_symbol_keys_stringified
    recs = [{ temp: 1.0 }, { temp: 2.0 }]
    df = CAFrame.from_records(recs)
    assert_equal ["temp"], df.variable_names
    assert_equal :float64, df["temp"].data_type
  end

  def test_empty_records
    df = CAFrame.from_records([])
    assert_equal 0, df.nrow
    assert_equal [], df.variable_names
  end

  def test_non_array_raises
    assert_raise(ArgumentError) { CAFrame.from_records({ "a" => 1 }) }
  end

  # --- to_records (inverse) ---------------------------------------------

  def test_to_records_normalizes_undef_to_nil_and_nd_to_array
    df = CAFrame.from_records([
      { "h" => 53, "temp" => [21, 25, 29] },
      { "h" => nil, "temp" => [20, 24, 30] },
    ])
    recs = df.to_records
    assert_equal 53, recs[0]["h"]
    assert_nil recs[1]["h"]                      # UNDEF -> nil
    assert_equal [21, 25, 29], recs[0]["temp"]   # N-D CArray -> Ruby Array
    assert_instance_of Array, recs[0]["temp"]
  end

  def test_to_records_round_trips_through_from_records
    df = CAFrame.from_records([
      { "station" => "Tokyo", "h" => 53, "temp" => [21, 25, 29], "p" => 1018.0 },
      { "station" => "Osaka", "h" => nil, "temp" => [20, 24, 30], "p" => 1017.9 },
    ])
    df2 = CAFrame.from_records(df.to_records)
    assert_equal df.data_types, df2.data_types
    assert_equal df["h"].to_a, df2["h"].to_a
    assert_equal df["temp"].to_a, df2["temp"].to_a
  end

  def test_to_records_is_json_serializable
    require "json"
    df = CAFrame.from_records([{ "a" => 1, "b" => nil }])
    json = JSON.generate(df.to_records)
    assert_equal [{ "a" => 1, "b" => nil }], JSON.parse(json)
  end
end

require "test/unit"
require "carray"

# Frame verbs on N-D columns: each position on the trailing axes is a series
# down the rows, and a verb answers for an N-D column what it answers for each
# of those series.
class TestCAFrameNDColumns < Test::Unit::TestCase
  def gappy
    w = CA_FLOAT64([[1, 9], [9, 20], [3, 9], [4, 40]])
    w[0, 1] = UNDEF
    w[1, 0] = UNDEF
    w[2, 1] = UNDEF
    w
  end

  def test_fill_runs_down_the_rows
    { ffill: :forward, bfill: :backward, linear: :linear }.each do |m, core|
      got = CAFrame.new("w" => gappy).fill("w", m)["w"]
      want = gappy.strip_mask(method: core, axis: 0)
      assert_equal want.to_a, got.to_a, m.to_s
    end
  end

  def test_linear_fill_takes_the_index_for_each_position
    w = gappy
    CAFrame.new("w" => w, index: CA_FLOAT64([0, 1, 3, 4])).fill("w", :linear)
    assert_in_delta 1 + 2.0 / 3, w[1, 0], 1e-12
    assert_in_delta 20 + 20 * 2.0 / 3, w[2, 1], 1e-12
    assert_equal UNDEF, w[0, 1]
  end

  def test_linear_fill_of_a_time_column_with_an_index
    t = CArray.int64(4, 2).seq!.time(unit: :D)
    t[1, 0] = UNDEF
    CAFrame.new("t" => t, index: CA_FLOAT64([0, 1, 3, 4])).fill("t", :linear)
    assert_equal %w[1970-01-01 1970-01-02 1970-01-05 1970-01-07], t[nil, 0].to_a.map(&:to_s)
  end

  def test_records_round_trip_a_three_dimensional_column
    c = CArray.int32(2, 2, 2).seq!
    c[1, 0, 1] = UNDEF
    recs = CAFrame.new("c" => c).to_records
    assert_equal [[4, nil], [6, 7]], recs[1]["c"]
    back = CAFrame.from_records(recs)["c"]
    assert_equal [2, 2, 2], back.shape
    assert_equal c.to_a, back.to_a
  end

  def test_records_build_a_column_from_nested_cells
    r = CAFrame.from_records([{ "a" => [[1, 2], [3, 4]] }, { "a" => [[5, 6], [7, 8]] }])["a"]
    assert_equal :int64, r.data_type
    assert_equal [[[1, 2], [3, 4]], [[5, 6], [7, 8]]], r.to_a
    ragged = CAFrame.from_records([{ "a" => [[1, 2], [3]] }, { "a" => [[1, 2], [3, 4]] }])["a"]
    assert_equal [2], ragged.shape
  end

  def test_records_with_no_value_build_an_object_column
    assert_equal :object, CAFrame.from_records([{ "a" => [nil, nil] }, { "a" => [nil, nil] }])["a"].data_type
    assert_equal :object, CAFrame.from_records([{ "a" => [] }, { "a" => [] }])["a"].data_type
  end

  def test_unstack_column_refuses_a_column_with_no_position
    df = CAFrame.new("a" => CArray.int32(3, 0))
    assert_raise(ArgumentError) { df.unstack_column("a") }
  end

  def test_unstack_column_undoes_a_stack_of_nd_columns
    w1 = CA_FLOAT64([[1, 2], [3, 4], [5, 6]])
    w2 = w1 + 10
    s = CAFrame.new("w1" => w1, "w2" => w2).stack_columns(%w[w1 w2], into: "w")
    u = s.unstack_column("w", into: %w[w1 w2])
    assert_equal w1.to_a, u["w1"].to_a
    assert_equal w2.to_a, u["w2"].to_a
    u["w1"][0, 0] = 100
    assert_equal 100.0, w1[0, 0]
    assert_equal 4, s.unstack_column("w").ncol
  end

  def test_a_new_column_name_is_a_non_empty_string
    df = CAFrame.new("a" => CA_INT32([1]), "b" => CA_INT32([2]))
    assert_raise(TypeError) { df.stack_columns(%w[a b], into: nil) }
    assert_raise(ArgumentError) { df.stack_columns(%w[a b], into: "") }
    s = df.stack_columns(%w[a b], into: "v")
    assert_raise(TypeError) { s.unstack_column("v", into: [nil, "q"]) }
  end

  def test_stack_compares_indexes_holding_nan
    g = CAFrame.new("v" => CA_INT32([1, 2]), index: CA_FLOAT64([1.0, Float::NAN]))
    assert_equal [2, 2], CAFrame.stack(g, g)["v"].shape
  end

  def test_an_empty_frame_has_to_agree_on_trailing_dimensions
    x = CAFrame.new("w" => CArray.float64(1, 2))
    e = CAFrame.new("w" => CArray.float64(0, 3))
    assert_raise(ArgumentError) { CAFrame.meld(x, e) }
    assert_raise(ArgumentError) { CAFrame.concatenate(e, x) }
    assert_equal 1, CAFrame.meld(x, CAFrame.new("w" => CArray.float64(0, 2))).nrow
  end

  def test_pivot_refuses_an_nd_key
    df = CAFrame.new("k" => CA_FLOAT64([[1, 2], [3, 4]]), "v" => CA_INT32([1, 2]))
    e = assert_raise(ArgumentError) { df.pivot(index: "k", columns: "v", values: "v") }
    assert_match(/\Apivot: index:/, e.message)
  end

  def test_stack_rows_names_itself_in_its_key_errors
    f = CAFrame.new("k" => CA_INT32([1, 1, 2, 2]), "x" => CA_INT32([1, 2, 3, 4]))
    assert_match(/\Astack_rows:/, assert_raise(KeyError) { f.stack_rows(by: "nope") }.message)
    assert_match(/\Astack_rows:/, assert_raise(ArgumentError) { f.stack_rows(by: CA_INT32([1])) }.message)
    w = CAFrame.new("w" => CA_FLOAT64([[1, 2], [3, 4]]), "k" => CA_INT32([1, 1]))
    assert_match(/\Astack_rows:/, assert_raise(ArgumentError) { w.stack_rows(by: "w") }.message)
  end

  def test_stack_rows_refuses_a_frame_with_only_the_key
    f = CAFrame.new("k" => CA_INT32([1, 1, 2, 2]))
    e = assert_raise(ArgumentError) { f.stack_rows(by: "k") }
    assert_match(/\Astack_rows:/, e.message)
    indexed = CAFrame.new({ "k" => CA_INT32([1, 1, 2, 2]) }, index: CA_INT32([10, 20, 30, 40]))
    assert_equal 4, indexed.stack_rows(by: "k").unstack_rows.nrow
  end

  def test_group_order_statistics_reduce_an_nd_column_down_the_rows
    df = CAFrame.new("k" => CA_INT32([0, 0, 1, 1, 1]),
                     "w" => CA_FLOAT64([[1, 2], [3, 4], [5, 6], [7, 8], [9, 10]]))
    out = df.group_by("k").aggregate("m" => ["w", :median])
    assert_equal [[2.0, 3.0], [7.0, 8.0]], out["m"].to_a
    p100 = df.group_by("k").aggregate("p" => ["w", :percentile, 100.0])["p"]
    assert_equal [[3.0, 4.0], [9.0, 10.0]], p100.to_a
  end

  def test_aggregate_passes_arguments_and_keywords
    df = CAFrame.new("k" => CA_INT32([0, 0, 0, 1]), "v" => CA_FLOAT64([1, 2, 3, 4]))
    out = df.group_by("k").aggregate("p" => ["v", :percentile, 50.0, min_count: 2])
    assert_equal [2.0, UNDEF], out["p"].to_a
    assert_raise(ArgumentError) { df.group_by("k").aggregate("x" => ["v", ->(c) { c.sum }, 1]) }
  end

  def test_table_shows_nd_cells_as_scalar_cells
    df = CAFrame.new("y" => CA_FLOAT64([[1 / 3.0, 2], [1, 2]]),
                     "t" => CArray.int64(2, 2).seq!.time(unit: :D))
    text = df.to_table(precision: 3)
    assert_include text, "[0.333, 2.0]"
    assert_include text, "[1970-01-01, 1970-01-02]"
  end
end

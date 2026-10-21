# frozen_string_literal: true

require "test/unit"
require "carray"

# df.sum / df.mean / ... reduce each column over all the rows, as a frame of
# one row: the group reductions with every row in one group.
class TestCAFrameReduceAllRows < Test::Unit::TestCase
  def frame
    v = CA_FLOAT64([1, 2, 3, 6])
    v[1] = UNDEF
    CAFrame.new({ "v" => v,
                  "n" => CA_INT32([4, 3, 2, 1]),
                  "t" => CArray.time_series("2024-01-01", count: 4, unit: :D),
                  "s" => CArray.string(%w[a b c d]),
                  "p" => CArray.float64(4, 2) { |i, j| i * 10 + j } },
                axis_name: "row", index: CA_INT32([10, 11, 12, 13]))
  end

  def test_every_column_that_has_it
    out = frame.mean
    assert_equal 1, out.nrow
    assert_equal %w[v n t p], out.column_names
    assert_nil out.index
    assert_equal [10.0 / 3], out["v"].to_a
    assert_equal [2.5], out["n"].to_a
    assert_equal [[15.0, 16.0]], out["p"].to_a
  end

  def test_named_columns
    out = frame.max("v", "n")
    assert_equal %w[v n], out.column_names
    assert_equal [6.0], out["v"].to_a
    assert_equal [4], out["n"].to_a
  end

  def test_a_column_keeps_its_type_where_the_reduction_keeps_it
    out = frame.min("t", "s")
    assert_kind_of CATime, out["t"]
    assert_equal "2024-01-01", out["t"][0].to_s
    assert_equal ["a"], out["s"].to_a
  end

  def test_the_answers_of_the_column_reductions
    df = frame
    %i[sum mean min max median variance stddev count first last nunique].each do |red|
      want = red == :count ? df["v"].count_not_masked : df["v"].public_send(red)
      got  = df.public_send(red, "v")["v"][0]
      assert_in_delta want, got, 1e-12, red.to_s
    end
  end

  def test_keywords
    df = frame
    assert_equal [UNDEF], df.mean("v", min_count: 4)["v"].to_a
    assert_equal [-1.0], df.mean("v", min_count: 4, fill_value: -1.0)["v"].to_a
    anomaly = df["n"] - df.mean("n", keep_rows: true)
    assert_equal [1.5, 0.5, -0.5, -1.5], anomaly.to_a
  end

  def test_no_rows
    df = CAFrame.new("a" => CA_FLOAT64([]))
    assert_equal [0.0], df.sum["a"].to_a
    assert_equal [UNDEF], df.mean["a"].to_a
    assert_equal [0], df.count["a"].to_a
  end

  def test_refusals
    assert_raise(KeyError) { frame.mean("nope") }
    assert_raise(CArray::DataTypeError) { frame.mean("s") }
    assert_raise(ArgumentError) { frame.first("v", min_count: 1) }
  end
end

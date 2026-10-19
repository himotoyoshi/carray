require "test/unit"
require "carray"

# GroupedFrame#aggregate with a block yields the grouped frame once; the
# block returns a Hash of per-group CArrays, computed with grp[...]
# iterators and CArray arithmetic. grp[...] takes a column name or any
# CArray with one entry per row.

class TestCAFrameGroupAggregateBlock < Test::Unit::TestCase

  def frame
    station = CA_OBJECT(%w[a b a b a b])
    station[5] = UNDEF                       # a row in no group
    temp = CA_FLOAT64([1, 2, 3, 4, 9, 100])
    w    = CA_FLOAT64([1, 1, 2, 1, 1, 1])
    qc   = CA_INT32([0, 0, 1, 0, 0, 0])
    CAFrame.new("station" => station, "temp" => temp, "w" => w, "qc" => qc)
  end

  def test_columns_from_iterators_and_arithmetic
    df = frame
    out = df.group_by("station").aggregate do |g|
      { "mean"  => g["temp"].mean,
        "range" => g["temp"].max - g["temp"].min,
        "wmean" => g[df["temp"] * df["w"]].sum / g["w"].sum,
        "p50"   => g["temp"].percentile(50),
        "n"     => g["temp"].group_sizes }
    end
    assert_equal %w[a b], out.index.to_a
    assert_equal %w[mean range wmean p50 n], out.column_names
    assert_in_delta 13.0 / 3, out["mean"][0], 1e-12
    assert_equal [8.0, 2.0], out["range"].to_a
    assert_equal [16.0 / 4, 3.0], out["wmean"].to_a        # a: (1 + 6 + 9) / 4
    assert_equal [3.0, 3.0], out["p50"].to_a
    assert_equal [3, 2], out["n"].to_a
  end

  # A masked cell is left out, so masking a column is a filter for one
  # column of the result.
  def test_masked_array_leaves_rows_out
    df = frame
    out = df.group_by("station").aggregate do |g|
      { "all" => g["temp"].mean,
        "ok"  => g[df["temp"].mask_where(df["qc"].ne(0))].mean }
    end
    assert_equal [5.0, 3.0], out["ok"].to_a                  # a: (1 + 9) / 2
  end

  def test_keep_rows
    df = frame
    out = df.group_by("station").aggregate(keep_rows: true) { |g| { "m" => g["temp"].mean } }
    assert_equal 6, out.nrow
    assert_equal [3.0, 3.0], [out["m"][1], out["m"][3]]
    assert_equal UNDEF, out["m"][5]                           # the row in no group
  end

  # With a composite key the key columns come first, and a result column may
  # not take a key column's name.
  def test_composite_key
    df = CAFrame.new("k1" => CA_OBJECT(%w[x x y]), "k2" => CA_INT32([1, 1, 2]),
                     "v"  => CA_FLOAT64([1, 3, 5]))
    grp = df.group_by("k1", "k2")
    out = grp.aggregate { |g| { "v" => g["v"].sum } }
    assert_equal %w[k1 k2 v], out.column_names
    assert_equal [4.0, 5.0], out["v"].to_a
    assert_raise(ArgumentError) { grp.aggregate { |g| { "k1" => g["v"].sum } } }
  end

  # resample(fill: true) has groups with no rows; the block's columns have an
  # entry for each.
  def test_resample_with_empty_bins
    t  = CArray.time(["2024-01-01T00:00", "2024-01-01T00:30", "2024-01-01T03:00"])
    df = CAFrame.new("time" => t, "v" => CA_FLOAT64([1, 2, 4]))
    out = df.resample("time", "1 hour", fill: true).aggregate { |g| { "n" => g["v"].group_sizes,
                                                                        "s" => g["v"].sum } }
    assert_equal 4, out.nrow
    assert_equal [2, 0, 0, 1], out["n"].to_a
    assert_equal [3.0, 0.0, 0.0, 4.0], out["s"].to_a
  end

  # An N-D array is grouped along its first axis.
  def test_nd_array
    df = frame
    prof = CArray.float64(6, 2) { |i, j| i * 10 + j }
    out = df.group_by("station").aggregate { |g| { "p" => g[prof].mean(axis: 0) } }
    assert_equal [2, 2], out["p"].shape
    assert_equal [20.0, 21.0], out["p"][0, nil].to_a          # rows 0, 2, 4
  end

  def test_face_column
    t  = CArray.time(["2024-01-01", "2024-01-03", "2024-01-02"])
    df = CAFrame.new("k" => CA_OBJECT(%w[a a b]), "t" => t)
    out = df.group_by("k").aggregate { |g| { "first" => g["t"].min } }
    assert_kind_of CATime, out["first"]
    assert_equal t[0], out["first"][0]
  end

  def test_refusals
    df  = frame
    grp = df.group_by("station")
    assert_raise(ArgumentError) { grp.aggregate("m" => ["temp", :mean]) { {} } }
    assert_raise(ArgumentError) { grp.aggregate { 1 } }
    assert_raise(ArgumentError) { grp.aggregate { { "m" => 3.0 } } }
    assert_raise(ArgumentError) { grp.aggregate { { "m" => df["temp"] } } }   # per row, not per group
    assert_raise(TypeError)     { grp.aggregate { |g| { m: g["temp"].mean } } }
    assert_raise(ArgumentError) { grp[CA_FLOAT64([1, 2])] }
    assert_raise(TypeError)     { grp[:temp] }
    assert_raise(KeyError)      { grp["none"] }
  end

  def test_iterator_of_an_array
    df = frame
    grp = df.group_by("station")
    assert_equal grp["temp"].sum.to_a, grp[df["temp"]].sum.to_a
    assert_equal [16.0, 6.0], grp[df["temp"] * df["w"]].sum.to_a
  end
end

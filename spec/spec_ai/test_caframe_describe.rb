require "test/unit"
require "carray"

# CAFrame#describe: one row of statistics per column.
class TestCAFrameDescribe < Test::Unit::TestCase
  def setup
    temp = CA_FLOAT64([22.1, 19.0, 0.0])
    temp[2] = UNDEF
    @df = CAFrame.new(
      "station" => CA_OBJECT(["tokyo", "osaka", "tokyo"]),
      "temp"    => temp,
      "time"    => CArray.time(["2024-01-02", "2024-01-01", "2024-01-03"], unit: :D),
      "rain"    => CA_BOOLEAN([true, false, true]),
      "z"       => CA_CMPLX128([1, 2, 3]),
      "cat"     => CA_OBJECT(["a", "b", "a"]).categorize,
      "wind"    => CA_FLOAT64([[1, 2], [3, 4], [5, 6]]),
    )
    @d = @df.describe
  end

  def row(name)
    @d.at(name)
  end

  def test_one_row_per_column_indexed_by_name
    assert_equal @df.column_names, @d.index.to_a
    assert_equal "column", @d.axis_name
    assert_equal %w[type count masked unique min max mean stddev], @d.column_names
  end

  def test_numbers
    r = row("temp")
    assert_equal "float64", r["type"]
    assert_equal [2, 1, 2], [r["count"], r["masked"], r["unique"]]
    assert_equal [19.0, 22.1], [r["min"], r["max"]]
    assert_in_delta 20.55, r["mean"], 1e-12
    assert_in_delta Math.sqrt(((22.1 - 20.55)**2 + (19.0 - 20.55)**2) / 1), r["stddev"], 1e-12
  end

  def test_text_gives_counts_only
    r = row("station")
    assert_equal ["object", 3, 0, 2], r.values_at("type", "count", "masked", "unique")
    %w[min max mean stddev].each { |s| assert UNDEF.equal?(r[s]), s }
  end

  def test_time_statistics_are_times
    r = row("time")
    assert_equal "CATime", r["type"]
    assert_equal "2024-01-01", r["min"].to_s
    assert_equal "2024-01-03", r["max"].to_s
    assert_equal "2024-01-02", r["mean"].to_s
    assert_kind_of CATimedelta::Element, r["stddev"]
  end

  def test_boolean_mean_is_the_share_of_trues
    r = row("rain")
    assert_equal [0, 1], [r["min"], r["max"]]
    assert_in_delta 2.0 / 3, r["mean"], 1e-12
  end

  def test_complex_has_no_order_and_no_unique
    r = row("z")
    assert UNDEF.equal?(r["unique"])
    assert UNDEF.equal?(r["min"])
    assert_equal Complex(2, 0), r["mean"]
  end

  def test_categorical_is_a_face_without_order
    r = row("cat")
    assert_equal ["CACategorical", 2], r.values_at("type", "unique")
    assert UNDEF.equal?(r["min"])
    assert UNDEF.equal?(r["mean"])
  end

  def test_nd_column_counts_cells_and_shows_its_shape
    r = row("wind")
    assert_equal "float64[2]", r["type"]
    assert_equal 6, r["count"]
    assert_equal [1.0, 6.0, 3.5], r.values_at("min", "max", "mean")
  end

  def test_an_all_masked_column
    e = CA_FLOAT64([1, 2])
    e[] = UNDEF
    r = CAFrame.new("e" => e).describe.at("e")
    assert_equal [0, 2, 0], r.values_at("count", "masked", "unique")
    %w[min max mean stddev].each { |s| assert UNDEF.equal?(r[s]), s }
  end

  def test_a_record_column
    st = CArray.struct { float64 :lat; float64 :lng }
    pos = CARecord.new(st, 3)
    pos["lat"][] = [35.0, 35.0, 34.0]
    pos["lng"][] = [139.0, 139.0, 135.0]
    r = CAFrame.new("pos" => pos).describe.at("pos")
    assert_equal ["CARecord", 3, 2], r.values_at("type", "count", "unique")
    assert UNDEF.equal?(r["mean"])
  end

  def test_names_pick_the_columns
    d = @df.describe("temp", "station")
    assert_equal ["temp", "station"], d.index.to_a
    assert_raise(KeyError) { @df.describe("nope") }
  end

  def test_the_index_is_not_a_row
    d = @df.set_index("station").describe
    assert_not_include d.index.to_a, "station"
  end

  def test_shows_as_a_table
    text = @d.to_table
    assert_match(/^temp\s+float64\s+2\s+1\s+2\s+19\.0\s+22\.1/, text)
    assert_match(/^time\s+CATime\s+3\s+0\s+3\s+2024-01-01\s+2024-01-03/, text)
  end
end

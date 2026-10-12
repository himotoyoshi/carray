require "test/unit"
require "carray"

# stack_columns makes columns side by side in a file one N-D column;
# unstack_column splits it back.
class TestCAFrameStackColumns < Test::Unit::TestCase
  # A frame laid out like a table of monthly values: a key, 12 values, an
  # annual one, then 36 values as month x (max, min, mean).
  def setup
    cols = { "mesh" => CA_OBJECT(%w[m1 m2]) }
    (1..12).each { |m| cols["p%02d" % m] = CA_INT32([m * 10, m * 10 + 1]) }
    cols["p_year"] = CA_INT32([999, 998])
    @temp_names = []
    (1..12).each do |m|
      %w[max min mean].each_with_index do |kind, j|
        name = "t%02d_#{kind}" % m
        @temp_names << name
        cols[name] = CA_INT32([m * 100 + j, -(m * 100 + j)])
      end
    end
    @df = CAFrame.new(cols)
  end

  def test_a_range_of_names_runs_in_the_frames_order
    s = @df.stack_columns("p01".."p12", into: "precip")
    assert_equal %w[mesh precip p_year], s.column_names.first(3)
    assert_equal [2, 12], s["precip"].shape
    assert_equal (1..12).map { |m| m * 10 }, s["precip"][0, nil].to_a
    assert_equal [2, 11], @df.stack_columns("p01"..."p12", into: "x")["x"].shape
  end

  def test_shape_arranges_the_columns_in_row_major_order
    s = @df.stack_columns("t01_max".."t12_mean", into: "temp", shape: [12, 3])
    assert_equal [2, 12, 3], s["temp"].shape
    assert_equal [702, -702], s["temp"][nil, 6, 2].to_a     # July's mean
    assert_equal %w[mesh p01], s.column_names.first(2)
    assert_equal "temp", s.column_names.last
  end

  def test_an_array_keeps_its_order_and_a_regexp_the_frames
    assert_equal [20, 10], @df.stack_columns(%w[p02 p01], into: "x")["x"][0, nil].to_a
    assert_equal [10, 20, 30], @df.stack_columns(/\Ap0[1-3]\z/, into: "x")["x"][0, nil].to_a
  end

  def test_the_new_column_is_a_view_of_the_old_ones
    s = @df.stack_columns("p01".."p12", into: "precip")
    s["precip"][0, 1] = -5
    assert_equal(-5, @df["p02"][0])
  end

  def test_unstack_column_is_the_inverse
    s = @df.stack_columns("p01".."p12", into: "precip")
           .stack_columns("t01_max".."t12_mean", into: "temp", shape: [12, 3])
    back = s.unstack_column("precip", into: (1..12).map { |m| "p%02d" % m })
            .unstack_column("temp", into: @temp_names)
    assert_equal @df.column_names, back.column_names
    @df.column_names.each { |n| assert_equal @df[n].to_a, back[n].to_a }
  end

  def test_unstack_column_names_the_positions_without_into
    s = @df.stack_columns("t01_max".."t12_mean", into: "temp", shape: [12, 3])
    names = s.unstack_column("temp").column_names
    assert_equal %w[temp_0_0 temp_0_1 temp_0_2], names[14, 3]
    assert_equal "temp_11_2", names.last
  end

  def test_columns_of_other_shapes_and_types
    d = CAFrame.new("a" => CA_INT32([[1, 2]]), "b" => CA_INT32([[3, 4]]))
    assert_equal [1, 2, 2], d.stack_columns(%w[a b], into: "x")["x"].shape
    d = CAFrame.new("a" => CA_INT32([1]), "b" => CA_FLOAT64([2.5]))
    assert_equal [[1.0, 2.5]], d.stack_columns(%w[a b], into: "x")["x"].to_a
    d = CAFrame.new("a" => CA_INT32([[1, 2]]), "b" => CA_INT32([3]))
    assert_raise(ArgumentError) { d.stack_columns(%w[a b], into: "x") }
  end

  def test_refusals
    assert_raise(ArgumentError) { @df.stack_columns("p12".."p01", into: "x") }
    assert_raise(KeyError)      { @df.stack_columns("p01".."p99", into: "x") }
    assert_raise(KeyError)      { @df.stack_columns(%w[p01 zz], into: "x") }
    assert_raise(ArgumentError) { @df.stack_columns(%w[p01 p01], into: "x") }
    assert_raise(ArgumentError) { @df.stack_columns(/zz/, into: "x") }
    assert_raise(ArgumentError) { @df.stack_columns("p01".."p12", into: "x", shape: [5, 2]) }
    assert_raise(ArgumentError) { @df.stack_columns("p01".."p12", into: "p_year") }
    assert_raise(ArgumentError) { @df.stack_columns(1..3, into: "x") }
    assert_raise(ArgumentError) { @df.unstack_column("p01") }
    s = @df.stack_columns("p01".."p12", into: "precip")
    assert_raise(ArgumentError) { s.unstack_column("precip", into: %w[a b]) }
    assert_raise(ArgumentError) { s.unstack_column("precip", into: ["mesh"] + (1..11).map { |i| "q#{i}" }) }
  end
end

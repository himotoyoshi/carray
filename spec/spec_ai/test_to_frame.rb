require "test/unit"
require "carray"

# CArray#to_frame: rows along axis 0, one column per position along `axis`,
# each column a view of the array.
class TestToFrame < Test::Unit::TestCase

  def test_2d_columns_are_views_along_the_last_axis
    a = CArray.float64(3, 2).seq!
    df = a.to_frame("x", "y")
    assert_equal ["x", "y"], df.column_names
    assert_equal 3, df.nrow
    assert_equal [0.0, 2.0, 4.0], df["x"].to_a
    assert_equal [1.0, 3.0, 5.0], df["y"].to_a
  end

  def test_names_default_to_c_numbers
    assert_equal ["c0", "c1", "c2"], CArray.int32(2, 3).to_frame.column_names
  end

  def test_writes_and_masks_reach_both_ways
    a = CArray.float64(3, 2).seq!
    df = a.to_frame("x", "y")
    df["y"][2] = -1.0
    assert_equal(-1.0, a[2, 1])
    df["x"][0] = UNDEF
    assert_equal true, a.is_masked[0, 0]
    a[1, 1] = UNDEF
    assert_equal true, df["y"].is_masked[1]
  end

  def test_nd_columns_drop_the_column_axis
    b = CArray.float64(2, 3, 4).seq!
    df = b.to_frame("p", "q", "r", "s")
    assert_equal [2, 3], df["s"].shape
    assert_equal b[nil, nil, 3].to_a, df["s"].to_a
  end

  def test_axis_selects_the_column_axis
    b = CArray.float64(2, 3, 4).seq!
    df = b.to_frame("u", "v", "w", axis: 1)
    assert_equal [2, 4], df["w"].shape
    assert_equal b[nil, 2, nil].to_a, df["w"].to_a
    assert_equal ["c0", "c1", "c2"], b.to_frame(axis: -2).column_names
    assert_equal 4, b.to_frame(axis: nil).ncol
  end

  def test_face_columns_keep_their_class
    t = CArray.time(["2024-01-01", "2024-01-02", "2024-01-03", "2024-01-04"],
                    unit: :D).reshape(2, 2)
    assert_kind_of CATime, t.to_frame("a", "b")["b"]
  end

  def test_1d_takes_a_column_axis_from_newaxis
    a = CA_INT32([1, 2, 3])
    assert_equal [{"foo" => 1}, {"foo" => 2}, {"foo" => 3}],
                 a[nil, :_].to_frame("foo").to_records
  end

  def test_1d_is_refused
    e = assert_raise(ArgumentError) { CA_INT32([1, 2]).to_frame("a") }
    assert_match(/a\[nil, :_\]/, e.message)
  end

  def test_row_axis_cannot_be_the_column_axis
    a = CArray.int32(3, 2)
    assert_raise(ArgumentError) { a.to_frame(axis: 0) }
    assert_raise(ArgumentError) { a.to_frame(axis: -2) }
  end

  def test_axis_out_of_range_and_type
    a = CArray.int32(3, 2)
    assert_raise(ArgumentError) { a.to_frame(axis: 2) }
    assert_raise(TypeError) { a.to_frame(axis: 1.0) }
  end

  def test_names_are_checked
    a = CArray.int32(3, 2)
    assert_raise(ArgumentError) { a.to_frame("x") }
    assert_raise(ArgumentError) { a.to_frame("x", "y", "z") }
    assert_raise(ArgumentError) { a.to_frame("x", "x") }
    assert_raise(TypeError) { a.to_frame(:x, :y) }
  end

end

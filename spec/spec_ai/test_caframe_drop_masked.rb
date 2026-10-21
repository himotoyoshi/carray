# frozen_string_literal: true

require "test/unit"
require "carray"

# drop_masked keeps the rows with no masked cell in the columns named, or in
# every column.
class TestCAFrameDropMasked < Test::Unit::TestCase
  def frame
    a = CA_FLOAT64([1, 2, 3, 4])
    a[1] = UNDEF
    b = CA_OBJECT(%w[w x y z])
    b[2] = UNDEF
    p = CArray.float64(4, 2).seq
    p[3, 1] = UNDEF
    return CAFrame.new({ "a" => a, "b" => b, "p" => p },
                       axis_name: "t", index: CA_INT32([10, 11, 12, 13]))
  end

  def test_every_column
    out = frame.drop_masked
    assert_equal [10], out.index.to_a
    assert_equal %w[a b p], out.column_names
  end

  def test_the_columns_named
    assert_equal [10, 12, 13], frame.drop_masked("a").index.to_a
    assert_equal [10, 13], frame.drop_masked("a", "b").index.to_a
  end

  def test_a_masked_cell_of_an_nd_column_masks_its_row
    assert_equal [10, 11, 12], frame.drop_masked("p").index.to_a
  end

  def test_the_index_only_when_named
    df = frame
    df.index[0] = UNDEF
    assert_equal [12, 13], df.drop_masked("t", "a").index.to_a
    assert_equal [UNDEF, 12, 13], df.drop_masked("a").index.to_a
  end

  def test_a_nan_is_a_value
    df = CAFrame.new("x" => CA_FLOAT64([1, Float::NAN, 3]))
    assert_equal 3, df.drop_masked.nrow
    df["x"][:is_invalid] = UNDEF
    assert_equal [1.0, 3.0], df.drop_masked["x"].to_a
  end

  def test_a_view_of_the_frame
    df  = frame
    out = df.drop_masked("a")
    out["a"][1] = 99.0
    assert_equal 99.0, df["a"][2]
  end

  def test_an_unknown_name
    assert_raise(KeyError) { frame.drop_masked("nope") }
    assert_raise(TypeError) { frame.drop_masked(:a) }
  end

  def test_no_rows
    assert_equal 0, CAFrame.new("a" => CA_FLOAT64([])).drop_masked.nrow
  end
end

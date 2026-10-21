# CAFrame#to_a -- the rows as an Array of Arrays.

require "test/unit"
require "carray"
require "carray/categorical"

class TestCAFrameToA < Test::Unit::TestCase

  def test_rows_in_column_order
    df = CAFrame.new("a" => CA_INT32([1, 2]), "b" => CA_OBJECT(%w[x y]))
    assert_equal([[1, "x"], [2, "y"]], df.to_a)
  end

  def test_a_masked_cell_is_undef
    x = CA_FLOAT64([1, 2, 3])
    x[1] = UNDEF
    assert_equal([[1.0], [UNDEF], [3.0]], CAFrame.new("x" => x).to_a)
  end

  def test_the_index_is_left_out
    df = CAFrame.new({ "x" => CA_FLOAT64([1, 2]) }, index: CA_INT32([7, 8]), axis_name: "i")
    assert_equal([[1.0], [2.0]], df.to_a)
    assert_equal([[7, 1.0], [8, 2.0]], df.reset_index.to_a)
  end

  def test_cells_are_what_the_columns_give
    v = CArray.float64(2, 2).seq
    v[1, 1] = UNDEF
    t = CArray.time(["2026-01-01", "2026-01-02"])
    df = CAFrame.new("c" => CA_OBJECT(%w[a b]).categorize, "t" => t, "v" => v)
    rows = df.to_a
    assert_equal(["a", "b"], rows.map(&:first))
    assert_equal(t.to_a, rows.map { |r| r[1] })
    assert_equal([[0.0, 1.0], [2.0, UNDEF]], rows.map(&:last))
  end

  def test_no_rows_and_no_columns
    assert_equal([], CAFrame.new("x" => CA_FLOAT64([])).to_a)
    df = CAFrame.new({}, index: CA_INT32([1, 2]), axis_name: "i")
    assert_equal([[], []], df.to_a)
  end

  def test_filled_before_handing_over
    x = CA_FLOAT64([1, 2, 3])
    x[1] = UNDEF
    df = CAFrame.new("x" => x, "n" => CA_INT32([1, 2, 3]))
    assert_equal([[1.0, 1], [3.0, 3]], df.drop_masked.to_a)
    assert_equal([[1.0, 1], [0.0, 2], [3.0, 3]], df.strip_mask(0.0).to_a)
  end
end

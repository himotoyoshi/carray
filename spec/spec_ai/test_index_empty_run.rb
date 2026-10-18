require "test/unit"
require "carray"

# A run of no cells may start at the end of an axis, as an empty slice at the
# end of a Ruby Array does: a[2...2] of a length-2 array is empty. A run with
# cells still has to start on one, and every other bound keeps its check.

class TestIndexEmptyRun < Test::Unit::TestCase

  def a = CA_INT32([1, 2])

  def test_empty_ranges
    assert_equal [], a[2...2].to_a
    assert_equal [], a[2..].to_a
    assert_equal [], a[2...].to_a
    assert_equal [], a[-2...-2].to_a
    assert_equal [], a[0...0].to_a
  end

  # Past the end is out of range, empty or not, and a range in CArray that
  # ends before it starts reads backwards, so it is not empty.
  def test_still_out_of_range
    assert_raise(IndexError) { a[3...3] }
    assert_raise(IndexError) { a[3..] }
    assert_raise(IndexError) { a[-3...-3] }
    assert_raise(IndexError) { a[2..1] }
    assert_raise(IndexError) { a[0..2] }
  end

  def test_block_forms
    assert_equal [], a[[2, 0]].to_a
    assert_equal [], a[[2, 0, 1]].to_a
    assert_equal [], a[[2, 0, -1]].to_a
    assert_equal [], a[[2...2, 1]].to_a
    assert_equal [], a[[(2..), 1]].to_a
    assert_equal [], a[(2...2).step(1)].to_a
    assert_equal [], a[(2..).step(2)].to_a
    assert_raise(IndexError) { a[[3, 0]] }
    assert_raise(IndexError) { a[[2, 1]] }
    assert_raise(IndexError) { a[(3..).step(1)] }
  end

  def test_axis_of_length_zero
    e = CA_INT32([])
    assert_equal [], e[0...0].to_a
    assert_equal [], e[0..].to_a
    assert_equal [], e[[0, 0]].to_a
    assert_equal [], e[[nil, 2]].to_a
    assert_raise(IndexError) { e[[0, 1]] }
  end

  def test_the_view_works_on
    v = a[2...2]
    assert_equal [], v.copy.to_a
    assert_equal 0.0, v.sum
    assert_equal UNDEF, v.mean
    assert_equal [], v[0...0].to_a
  end

  def test_store_into_an_empty_run
    b = a
    b[2...2] = 9
    b[[2, 0]] = []
    assert_equal [1, 2], b.to_a
  end

  def test_two_dimensions
    m = CArray.int32(2, 3).seq!
    assert_equal [2, 0], m[nil, 3...3].shape
    assert_equal [0, 3], m[2...2, nil].shape
    assert_equal [0.0, 0.0], m[nil, 3...3].sum(axis: 1).to_a
  end

  # A frame selects rows through the same index.
  def test_frame_rows
    df = CAFrame.new("x" => CA_FLOAT64([1, 2]))
    assert_equal 0, df[2...2].nrow
    empty = CAFrame.new("k" => CA_OBJECT([]), "x" => CA_FLOAT64([]))
    assert_equal 0, empty[0...0].nrow
    assert_equal 0, empty.head(0).nrow
  end
end

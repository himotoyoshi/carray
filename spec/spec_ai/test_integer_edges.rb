require "test/unit"
require "carray"

# Integer arithmetic at the edge of the integer types.  Signed overflow and
# an out-of-range float-to-integer conversion have no defined result in C,
# and what they do differs between machines, so each case here pins the
# answer CArray gives whatever the machine.
class TestIntegerEdges < Test::Unit::TestCase

  # -- a shape too large to count ---------------------------------------

  # 274177 * 67280421310721 is 2**64 + 1.  Wrapped, the count would be 1
  # and every read past the first cell would leave the buffer.
  def test_a_view_whose_cell_count_overflows_is_refused
    a = CA_INT8([7])
    assert_raise(RuntimeError) { a.reshape(274177, 67280421310721) }
    assert_raise(RuntimeError) { a.refer(CA_INT8, [274177, 67280421310721]) }
    assert_raise(RuntimeError) { (a.lazy + 1).reshape(274177, 67280421310721) }
    assert_raise(RuntimeError) { CArray.int8(0).reshape(2**32, 2**32) }
    assert_raise(RuntimeError) { CA_INT8([7, 8]).tile(2**63 - 1) }
    assert_raise(RuntimeError) { CArray.float64(2**60) }
  end

  def test_an_empty_shape_is_empty_whatever_its_other_extents
    assert_equal [2**40, 2**40, 0], CArray.int8(0).reshape(2**40, 2**40, 0).shape
  end

  # -- a block index whose last cell is past any index ------------------

  def test_a_block_whose_bound_overflows_is_out_of_range
    a = CA_INT64([1, 2, 3])
    assert_raise(IndexError) { a[[0, 3, 2**63 - 1]] }
    assert_raise(IndexError) { a[[2, 2**63 - 1]] }
    assert_raise(IndexError) { a[[1, 3, 2**63 - 1]] = 99 }
    assert_equal [1, 2, 3], a.to_a
    assert_equal [3], a[(2..0).step(-2**63)].to_a
    assert_equal [1], a[(0..2).step(2**62)].to_a
  end

  # -- a uint64 index past what an index can hold -----------------------

  def test_a_uint64_index_of_2_63_or_more_is_out_of_range
    a = CA_INT8([1, 2, 3])
    assert_raise(IndexError) { a[CA_UINT64([2**64 - 1])] }
    assert_raise(IndexError) { a[CA_UINT64([2**64 - 1])] = 9 }
    assert_equal [1, 2, 3], a.to_a
    assert_equal [3, 1], a[CA_UINT64([2, 0])].to_a
  end

  # -- a position that is not a number ----------------------------------

  def test_a_percentile_of_nan_is_refused
    v = CA_FLOAT64([1, 2, 3, 4])
    assert_raise(ArgumentError) { v.percentile(Float::NAN) }
    g = v.group_by_category(CA_INT32([0, 0, 1, 1]).categorize)
    assert_raise(ArgumentError) { g.percentile(Float::NAN) }
    assert_raise(ArgumentError) { g.percentile(150) }
  end

  # Edges spanning more than a double holds, or a subnormal bin width,
  # would make the linearised bin position NaN.
  def test_histogram_edges_too_wide_or_too_narrow_bin_by_the_edges
    wide = CA_FLOAT64([9e307]).histogram1d(edges: CA_FLOAT64([-1e308, 0, 1e308]))
    assert_equal [0, 1], wide.counts.to_a
    thin = CA_FLOAT64([1.5e-320]).histogram1d(edges: CA_FLOAT64([0, 1e-320, 2e-320]))
    assert_equal [0, 1], thin.counts.to_a
  end
end

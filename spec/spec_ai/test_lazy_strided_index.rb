require "test/unit"
require "carray"

# A lazy binop pulls its two operands separately.  The left was pulled with
# the step the caller asked for and the right with a packed one, so a strided
# read came back as left[0], left[2], left[4] against right[0], right[1],
# right[2] -- values the expression cannot produce.
class TestLazyStridedIndex < Test::Unit::TestCase

  def setup
    @a = CArray.float64(6) { |i| i.to_f }
    @b = CArray.float64(6) { |i| i + 1.0 }
  end

  def test_binop_strided_block_matches_eager
    view  = CArray.fuse { @a + @b }
    eager = @a + @b
    [[0, 3, 2], [1, 2, 3], [0, 2, 5], [1, 3, 1], [2, 2, 2]].each do |spec|
      assert_equal eager[spec].to_a, view[spec].to_a,
                   "strided read #{spec.inspect} disagrees with the eager result"
    end
  end

  def test_binop_strided_block_two_dimensional
    a = CArray.float64(4, 6) { |i, j| i * 10.0 + j }
    b = CArray.float64(4, 6) { |i, j| j.to_f }
    view  = CArray.fuse { a * b }
    eager = a * b
    assert_equal eager[[0, 2, 2], [1, 3, 2]].to_a,
                 view[[0, 2, 2], [1, 3, 2]].to_a
  end

  def test_binop_strided_with_a_scalar_right
    view  = CArray.fuse { @a * 2.0 }
    eager = @a * 2.0
    assert_equal eager[[0, 3, 2]].to_a, view[[0, 3, 2]].to_a
  end

  def test_monop_and_bincmp_were_already_right
    assert_equal (@a * 10.0)[[0, 3, 2]].to_a,
                 CArray.fuse { @a * 10.0 }[[0, 3, 2]].to_a
    assert_equal (@a > @b)[[0, 3, 2]].to_a,
                 CArray.fuse { @a > @b }[[0, 3, 2]].to_a
  end

  def test_contiguous_reads_are_unchanged
    view  = CArray.fuse { @a - @b }
    eager = @a - @b
    assert_equal eager.to_a,          view.to_a
    assert_equal eager[1..4].to_a,    view[1..4].to_a
    assert_equal eager[nil].to_a,     view[nil].to_a
  end
end

require "test/unit"
require "carray"

# A lazy monop chain runs in place in one buffer.  When a step narrows the
# cells (complex abs: 16 bytes in, 8 out), the buffer must still hold the
# leaf's wider cells; sizing it by the answer overran the heap.
class TestLazyNarrowingChain < Test::Unit::TestCase

  def test_complex_abs_chain_answers_as_eager
    a = CArray.cmplx128(45) { |i| Complex(i, 1) }
    assert_equal a.abs.sqrt.to_a, a.lazy.abs.sqrt.to_a
    b = CArray.cmplx64(45) { |i| Complex(i, 1) }
    assert_equal b.abs.to_a, b.lazy.abs.to_a
    assert_equal b.abs.sqrt.to_a, b.lazy.abs.sqrt.to_a
  end

  def test_a_region_of_a_narrowing_chain_answers_as_eager
    a = CArray.cmplx128(6, 7) { |i| Complex(i, -1) }
    assert_equal a.abs[1..3, 2..5].to_a, a.lazy.abs[1..3, 2..5].to_a
  end

end

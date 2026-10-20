require "test/unit"
require "carray"

# An element-wise kernel is also called with its output on its input: by a
# bang, and by a lazy monop applied in place on its own scratch.  A body that
# stores part of a cell before reading the rest of it (a complex result
# built from one part of the input) must still read the cell as it was.

class TestKernelInPlace < Test::Unit::TestCase

  def cmplx (n)
    CArray.cmplx128(n) { |i| Complex(i + 1.0, 100.0 + i) }
  end

  def test_lazy_imag_reads_every_cell
    [1, 3, 4, 5, 7, 8, 9, 16, 33].each do |n|
      a = cmplx(n)
      assert_equal a.imag.to_a, a.lazy.imag.to_a, "n=#{n}"
      assert_equal a.imag.to_a, a.lazy.imag_i.to_a.map(&:real), "n=#{n}"
    end
    b = CArray.cmplx64(9) { |i| Complex(i, 10 + i) }
    assert_equal b.imag.to_a, b.lazy.imag.to_a
  end

  def test_a_bang_on_complex_cells
    a = cmplx(17)
    want = a.to_a.map(&:conj)
    a.conj!
    assert_equal want, a.to_a
    b = cmplx(17)
    want = b.to_a.map { |z| z * z }
    b.mul!(b)
    assert_equal want, b.to_a
    c = cmplx(17)
    d = cmplx(17).conj
    want = c.to_a.zip(d.to_a).map { |x, y| x * y }
    c.mul!(d)
    assert_equal want, c.to_a
  end

  def test_an_output_apart_from_its_inputs
    a = cmplx(17)
    assert_equal a.to_a.map { |z| z * z }, (a * a).to_a
    assert_equal a.to_a.map(&:imag), a.imag.to_a
  end
end

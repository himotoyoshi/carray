$LOAD_PATH.unshift File.expand_path('../../ext', __dir__)
$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'carray'
require 'test/unit'

# A complex array has no order but interpolates: the weights are real, so
# its real and imaginary parts are each interpolated.

class TestComplexInterpolation < Test::Unit::TestCase

  def test_linear_fetch_interpolates_both_parts
    z = CA_CMPLX128([0, Complex(1, 1), Complex(2, 4)])
    assert_equal Complex(1.5, 2.5), z.linear_fetch(1.5)
    assert_equal [Complex(0.5, 0.5), Complex(1.5, 2.5)],
                 z.linear_fetch(CA_FLOAT64([0.5, 1.5])).to_a
  end

  def test_linear_gap_fill_keeps_the_imaginary_part
    [:cmplx128, :cmplx64].each do |t|
      z = CArray.new(t, [3])
      z[] = [1, 0, Complex(3, 2)]
      z[1] = UNDEF
      assert_equal [Complex(1, 0), Complex(2, 1), Complex(3, 2)],
                   z.strip_mask(method: :linear).to_a, t.to_s
    end
  end

  def test_what_needs_an_order_refuses
    assert_raise(CArray::DataTypeError) { CA_CMPLX128([0, 1]).linear_section(0.5) }
    assert_raise(CArray::DataTypeError) { CA_CMPLX128([1]).elem_min(0, 0) }
    assert_raise(CArray::DataTypeError) { CA_CMPLX128([1]).elem_max(0, 0) }
  end

end

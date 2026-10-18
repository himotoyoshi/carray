# ----------------------------------------------------------------------------
#
#  spec_ai/test_object_to_complex_cell.rb
#
#  An object read into a complex cell through its to_c: the result is
#  taken only when it is a Complex, as Kernel#Complex takes it.
#
# ----------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestObjectToComplexCell < Test::Unit::TestCase

  def object_with_to_c (value)
    o = Object.new
    o.define_singleton_method(:to_c) { value }
    o
  end

  def test_a_complex_from_to_c_is_stored
    o = object_with_to_c(Complex(1, 2))
    a = CArray.cmplx128(2)
    a[0] = o
    assert_equal Complex(1.0, 2.0), a[0]
    a.fill(o)
    assert_equal [Complex(1.0, 2.0)] * 2, a.to_a
    assert_equal [Complex(1.0, 2.0)], CA_OBJECT([o]).to_type(:cmplx128).to_a
  end

  def test_a_non_complex_from_to_c_is_refused
    [1.5, 3, "x", nil].each do |value|
      o = object_with_to_c(value)
      a = CArray.cmplx128(2)
      assert_raise(TypeError) { a[0] = o }
      assert_raise(TypeError) { a.fill(o) }
      assert_raise(TypeError) { CArray.cmplx64(1)[0] = o }
    end
  end

  # A cast of an object array treats a cell that does not read as a
  # complex number as it treats any unreadable cell.
  def test_a_cast_masks_a_cell_whose_to_c_is_not_complex
    o = object_with_to_c(1.5)
    c = CA_OBJECT([o, Complex(3, 4)]).to_type(:cmplx128)
    assert_equal [true, false], c.is_masked.to_a
    assert_equal Complex(3.0, 4.0), c[1]
  end

end

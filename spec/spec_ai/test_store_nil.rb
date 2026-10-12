require "test/unit"
require "carray"

# nil is not a number: storing it into a numeric or boolean array raises,
# as Float(nil) / Integer(nil) / Complex(nil) do.  It used to become NaN
# (float), 0+0i (complex) or false (boolean).  to_type from an object
# array is a reading path where a cell with no number in it is UNDEF, for
# float, integer and complex alike.
class TestStoreNil < Test::Unit::TestCase

  def test_store_raises
    { float64: "Float", float32: "Float", cmplx128: "Complex", cmplx64: "Complex",
      int32: "Integer", uint8: "Integer" }.each do |t, name|
      a = CArray.new(t, [2])
      err = assert_raise(TypeError, t.to_s) { a[0] = nil }
      assert_equal "can't convert nil into #{name}", err.message
      assert_raise(TypeError, t.to_s) { a.fill(nil) }
      assert_raise(TypeError, t.to_s) { a[] = [nil, 1] }
      b = CArray.new(t, [2])
      b[0] = UNDEF
      assert_raise(TypeError, t.to_s) { b.strip_mask(nil) }
    end
    assert_raise(CArray::DataTypeError) { CArray.boolean(1)[0] = nil }
  end

  def test_object_keeps_nil
    a = CArray.object(2)
    a[0] = nil
    assert_nil a[0]
  end

  def test_to_type_reads_nil_as_undef
    o = CA_OBJECT([nil, "x", 1])
    assert_equal [UNDEF, UNDEF, 1.0], o.to_type(:float64).to_a
    assert_equal [UNDEF, UNDEF, 1],   o.to_type(:int32).to_a
    assert_equal [UNDEF, UNDEF, Complex(1, 0)], o.to_type(:cmplx128).to_a
    assert_equal [Complex(1, 2), Complex(3, 4)],
                 CA_OBJECT(["1+2i", Complex(3, 4)]).to_type(:cmplx128).to_a
  end

end

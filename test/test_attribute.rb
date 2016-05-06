$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArrayAttribute < Test::Unit::TestCase

  def test_attribute_basic_features
    a = CArray.new(CA_INT32, [4, 3, 2, 1])
    assert_instance_of(CArray, a)
    assert_equal(CA_OBJ_ARRAY, a.obj_type)
    assert_equal(CA_INT32, a.data_type)
    assert_equal(4, a.rank)
    assert_equal(CArray.sizeof(CA_INT32), a.bytes)
    assert_equal(24, a.elements)
    assert_equal([4, 3, 2, 1], a.dim)
    assert_equal(4, a.dim0)
    assert_equal(3, a.dim1)
    assert_equal(2, a.dim2)
    assert_equal(1, a.dim3)
  end

  def test_fixlen?
    assert_equal(CArray.new(CA_FIXLEN, [1], :bytes=>1).fixlen?, true)
    assert_equal(CArray.boolean(1).fixlen?,     false)
    assert_equal(CArray.int8(1).fixlen?,     false)
    assert_equal(CArray.uint8(1).fixlen?,    false)
    assert_equal(CArray.int16(1).fixlen?,    false)
    assert_equal(CArray.uint16(1).fixlen?,   false)
    assert_equal(CArray.int32(1).fixlen?,    false)
    assert_equal(CArray.uint32(1).fixlen?,   false)
    assert_equal(CArray.int64(1).fixlen?,    false)
    assert_equal(CArray.uint64(1).fixlen?,   false)
    assert_equal(CArray.float32(1).fixlen?,  false)
    assert_equal(CArray.float64(1).fixlen?,  false)
    if CArray.data_type?(:float128)
      assert_equal(CArray.float128(1).fixlen?, false)
    end
    if CArray::HAVE_COMPLEX
      assert_equal(CArray.cmplx64(1).fixlen?,  false)
      assert_equal(CArray.cmplx128(1).fixlen?, false)
      if CArray.data_type?(:cmplx256)
        assert_equal(CArray.cmplx256(1).fixlen?, false)
      end
    end
    assert_equal(CArray.object(1).fixlen?,   false)
  end

  def test_boolean?
    assert_equal(CArray.new(CA_FIXLEN, [1], :bytes=>1).boolean?, false)
    assert_equal(CArray.boolean(1).boolean?,     true)
    assert_equal(CArray.int8(1).boolean?,     false)
    assert_equal(CArray.uint8(1).boolean?,    false)
    assert_equal(CArray.int16(1).boolean?,    false)
    assert_equal(CArray.uint16(1).boolean?,   false)
    assert_equal(CArray.int32(1).boolean?,    false)
    assert_equal(CArray.uint32(1).boolean?,   false)
    assert_equal(CArray.int64(1).boolean?,    false)
    assert_equal(CArray.uint64(1).boolean?,   false)
    assert_equal(CArray.float32(1).boolean?,  false)
    assert_equal(CArray.float64(1).boolean?,  false)
    if CArray.data_type?(:float128)
      assert_equal(CArray.float128(1).boolean?, false)
    end
    if CArray::HAVE_COMPLEX
      assert_equal(CArray.cmplx64(1).boolean?,  false)
      assert_equal(CArray.cmplx128(1).boolean?, false)
      if CArray.data_type?(:cmplx256)
        assert_equal(CArray.cmplx256(1).boolean?, false)
      end
    end
    assert_equal(CArray.object(1).boolean?,   false)
  end

  def test_numeric?
    assert_equal(CArray.new(CA_FIXLEN, [1], :bytes=>1).integer?, false)
    assert_equal(CArray.boolean(1).integer?,     false)
    assert_equal(CArray.int8(1).integer?,     true)
    assert_equal(CArray.uint8(1).integer?,    true)
    assert_equal(CArray.int16(1).integer?,    true)
    assert_equal(CArray.uint16(1).integer?,   true)
    assert_equal(CArray.int32(1).integer?,    true)
    assert_equal(CArray.uint32(1).integer?,   true)
    assert_equal(CArray.int64(1).integer?,    true)
    assert_equal(CArray.uint64(1).integer?,   true)
    assert_equal(CArray.float32(1).integer?,  false)
    assert_equal(CArray.float64(1).integer?,  false)
    if CArray.data_type?(:float128)
      assert_equal(CArray.float128(1).integer?, false)
    end
    if CArray::HAVE_COMPLEX
      assert_equal(CArray.cmplx64(1).integer?,  false)
      assert_equal(CArray.cmplx128(1).integer?, false)
      if CArray.data_type?(:cmplx256)
        assert_equal(CArray.cmplx256(1).integer?, false)
      end
    end
    assert_equal(CArray.object(1).integer?,   false)
  end

  def test_integer?
    assert_equal(CArray.new(CA_FIXLEN, [1], :bytes=>1).integer?, false)
    assert_equal(CArray.boolean(1).integer?,     false)
    assert_equal(CArray.int8(1).integer?,     true)
    assert_equal(CArray.uint8(1).integer?,    true)
    assert_equal(CArray.int16(1).integer?,    true)
    assert_equal(CArray.uint16(1).integer?,   true)
    assert_equal(CArray.int32(1).integer?,    true)
    assert_equal(CArray.uint32(1).integer?,   true)
    assert_equal(CArray.int64(1).integer?,    true)
    assert_equal(CArray.uint64(1).integer?,   true)
    assert_equal(CArray.float32(1).integer?,  false)
    assert_equal(CArray.float64(1).integer?,  false)
    if CArray.data_type?(:float128)
      assert_equal(CArray.float128(1).integer?, false)
    end
    if CArray::HAVE_COMPLEX
      assert_equal(CArray.cmplx64(1).integer?,  false)
      assert_equal(CArray.cmplx128(1).integer?, false)
      if CArray.data_type?(:cmplx256)
        assert_equal(CArray.cmplx256(1).integer?, false)
      end
    end
    assert_equal(CArray.object(1).integer?,   false)
  end

  def test_unsigned?
    assert_equal(CArray.new(CA_FIXLEN, [1], :bytes=>1).unsigned?, false)
    assert_equal(CArray.boolean(1).unsigned?,  false)
    assert_equal(CArray.int8(1).unsigned?,     false)
    assert_equal(CArray.uint8(1).unsigned?,    true)
    assert_equal(CArray.int16(1).unsigned?,    false)
    assert_equal(CArray.uint16(1).unsigned?,   true)
    assert_equal(CArray.int32(1).unsigned?,    false)
    assert_equal(CArray.uint32(1).unsigned?,   true)
    assert_equal(CArray.int64(1).unsigned?,    false)
    assert_equal(CArray.uint64(1).unsigned?,   true)
    assert_equal(CArray.float32(1).unsigned?,  false)
    assert_equal(CArray.float64(1).unsigned?,  false)
    if CArray.data_type?(:float128)
      assert_equal(CArray.float128(1).unsigned?, false)
    end
    if CArray::HAVE_COMPLEX
      assert_equal(CArray.cmplx64(1).unsigned?,  false)
      assert_equal(CArray.cmplx128(1).unsigned?, false)
      if CArray.data_type?(:cmplx256)
        assert_equal(CArray.cmplx256(1).unsigned?, false)
      end
    end
    assert_equal(CArray.object(1).unsigned?,   false)
  end

  def test_float?
    assert_equal(CArray.new(CA_FIXLEN, [1], :bytes=>1).float?, false)
    assert_equal(CArray.boolean(1).float?,  false)
    assert_equal(CArray.int8(1).float?,     false)
    assert_equal(CArray.uint8(1).float?,    false)
    assert_equal(CArray.int16(1).float?,    false)
    assert_equal(CArray.uint16(1).float?,   false)
    assert_equal(CArray.int32(1).float?,    false)
    assert_equal(CArray.uint32(1).float?,   false)
    assert_equal(CArray.int64(1).float?,    false)
    assert_equal(CArray.uint64(1).float?,   false)
    assert_equal(CArray.float32(1).float?,  true)
    assert_equal(CArray.float64(1).float?,  true)
    if CArray.data_type?(:float128)
      assert_equal(CArray.float128(1).float?, true)
    end
    if CArray::HAVE_COMPLEX
      assert_equal(CArray.cmplx64(1).float?,  false)
      assert_equal(CArray.cmplx128(1).float?, false)
      if CArray.data_type?(:cmplx256)
        assert_equal(CArray.cmplx256(1).float?, false)
      end
    end
    assert_equal(CArray.object(1).float?,   false)
  end

  def test_complex?
    assert_equal(CArray.new(CA_FIXLEN, [1], :bytes=>1).complex?, false)
    assert_equal(CArray.boolean(1).complex?,  false)
    assert_equal(CArray.int8(1).complex?,     false)
    assert_equal(CArray.uint8(1).complex?,    false)
    assert_equal(CArray.int16(1).complex?,    false)
    assert_equal(CArray.uint16(1).complex?,   false)
    assert_equal(CArray.int32(1).complex?,    false)
    assert_equal(CArray.uint32(1).complex?,   false)
    assert_equal(CArray.int64(1).complex?,    false)
    assert_equal(CArray.uint64(1).complex?,   false)
    assert_equal(CArray.float32(1).complex?,  false)
    assert_equal(CArray.float64(1).complex?,  false)
    if CArray.data_type?(:float128)
      assert_equal(CArray.float128(1).complex?, false)
    end
    if CArray::HAVE_COMPLEX
      assert_equal(CArray.cmplx64(1).complex?,  true)
      assert_equal(CArray.cmplx128(1).complex?, true)
      if CArray.data_type?(:cmplx256)
        assert_equal(CArray.cmplx256(1).complex?, true)
      end
    end
    assert_equal(CArray.object(1).complex?,   false)
  end

  def test_object?
    assert_equal(CArray.new(CA_FIXLEN, [1], :bytes=>1).object?, false)
    assert_equal(CArray.boolean(1).object?,  false)
    assert_equal(CArray.int8(1).object?,     false)
    assert_equal(CArray.uint8(1).object?,    false)
    assert_equal(CArray.int16(1).object?,    false)
    assert_equal(CArray.uint16(1).object?,   false)
    assert_equal(CArray.int32(1).object?,    false)
    assert_equal(CArray.uint32(1).object?,   false)
    assert_equal(CArray.int64(1).object?,    false)
    assert_equal(CArray.uint64(1).object?,   false)
    assert_equal(CArray.float32(1).object?,  false)
    assert_equal(CArray.float64(1).object?,  false)
    if CArray.data_type?(:float128)
      assert_equal(CArray.float128(1).object?, false)
    end
    if CArray::HAVE_COMPLEX
      assert_equal(CArray.cmplx64(1).object?,  false)
      assert_equal(CArray.cmplx128(1).object?, false)
      if CArray.data_type?(:cmplx256)
        assert_equal(CArray.cmplx256(1).object?, false)
      end
    end
    assert_equal(CArray.object(1).object?,   true)
  end

  def test_entity?
    a = CArray.int32(3)
    assert_equal(a.entity?, true)
    assert_equal(a[].entity?, false)
    assert_equal(a[0..1].entity?, false)
    assert_equal(a[a>0].entity?, false)

    b = CScalar.int32()
    assert_equal(b.entity?, true)
    assert_equal(b[].entity?, false)
  end

  def test_virtual?
    a = CArray.int32(3)
    assert_equal(a.virtual?, false)
    assert_equal(a[].virtual?, true)
    assert_equal(a[0..1].virtual?, true)
    assert_equal(a[a>0].virtual?, true)

    b = CScalar.int32()
    assert_equal(b.virtual?, false)
    assert_equal(b[].virtual?, true)
  end

  def test_valid_index?
    a = CArray.int32(3,3)
    assert_equal(true, a.valid_index?(2,2))
    assert_equal(true, a.valid_index?(1,1))
    assert_equal(true, a.valid_index?(-1,-1))
    assert_equal(true, a.valid_index?(-3,-3))   

    assert_equal(true, a.valid_addr?(8))
    assert_equal(true, a.valid_addr?(4))
    assert_equal(true, a.valid_addr?(-4))
    assert_equal(true, a.valid_addr?(-8)) 
      
    assert_equal(false, a.valid_index?(1,3))
    assert_equal(false, a.valid_index?(-4,1))

    assert_equal(false, a.valid_addr?(9))   
    assert_equal(false, a.valid_addr?(-10))   
  end

  def test_same_shape?
    a = CArray.int32(4,3,2,1)
    b = CArray.int8(1,2,3,4)
    assert_equal(false, a.same_shape?(b))
    assert_equal(true, a.transposed.same_shape?(b))
  end

end

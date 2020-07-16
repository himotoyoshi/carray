
require 'carray'
require "rspec-power_assert"

describe "TestCArrayAttribute " do

  example "attribute_basic_features" do
    a = CArray.new(CA_INT32, [4, 3, 2, 1])
    is_asserted_by {  a.class == CArray }
    is_asserted_by {  CA_OBJ_ARRAY == a.obj_type }
    is_asserted_by {  CA_INT32 == a.data_type }
    is_asserted_by {  4 == a.rank }
    is_asserted_by {  CArray.sizeof(CA_INT32) == a.bytes }
    is_asserted_by {  24 == a.elements }
    is_asserted_by {  [4, 3, 2, 1] == a.dim }
    is_asserted_by {  4 == a.dim0 }
    is_asserted_by {  3 == a.dim1 }
    is_asserted_by {  2 == a.dim2 }
    is_asserted_by {  1 == a.dim3 }
  end

  example "fixlen?" do
    is_asserted_by {  CArray.new(CA_FIXLEN, [1], bytes: 1).fixlen? == true }
    is_asserted_by {  CArray.boolean(1).fixlen? == false }
    is_asserted_by {  CArray.int8(1).fixlen? == false }
    is_asserted_by {  CArray.uint8(1).fixlen? == false }
    is_asserted_by {  CArray.int16(1).fixlen? == false }
    is_asserted_by {  CArray.uint16(1).fixlen? == false }
    is_asserted_by {  CArray.int32(1).fixlen? == false }
    is_asserted_by {  CArray.uint32(1).fixlen? == false }
    is_asserted_by {  CArray.int64(1).fixlen? == false }
    is_asserted_by {  CArray.uint64(1).fixlen? == false }
    is_asserted_by {  CArray.float32(1).fixlen? == false }
    is_asserted_by {  CArray.float64(1).fixlen? == false }
    if CArray.data_type?(:float128)
      is_asserted_by {  CArray.float128(1).fixlen? == false }
    end
    if CArray::HAVE_COMPLEX
      is_asserted_by {  CArray.cmplx64(1).fixlen? == false }
      is_asserted_by {  CArray.cmplx128(1).fixlen? == false }
      if CArray.data_type?(:cmplx256)
        is_asserted_by {  CArray.cmplx256(1).fixlen? == false }
      end
    end
    is_asserted_by {  CArray.object(1).fixlen? == false }
  end

  example "boolean?" do
    is_asserted_by {  CArray.new(CA_FIXLEN, [1], bytes: 1).boolean? == false }
    is_asserted_by {  CArray.boolean(1).boolean? == true }
    is_asserted_by {  CArray.int8(1).boolean? == false }
    is_asserted_by {  CArray.uint8(1).boolean? == false }
    is_asserted_by {  CArray.int16(1).boolean? == false }
    is_asserted_by {  CArray.uint16(1).boolean? == false }
    is_asserted_by {  CArray.int32(1).boolean? == false }
    is_asserted_by {  CArray.uint32(1).boolean? == false }
    is_asserted_by {  CArray.int64(1).boolean? == false }
    is_asserted_by {  CArray.uint64(1).boolean? == false }
    is_asserted_by {  CArray.float32(1).boolean? == false }
    is_asserted_by {  CArray.float64(1).boolean? == false }
    if CArray.data_type?(:float128)
      is_asserted_by {  CArray.float128(1).boolean? == false }
    end
    if CArray::HAVE_COMPLEX
      is_asserted_by {  CArray.cmplx64(1).boolean? == false }
      is_asserted_by {  CArray.cmplx128(1).boolean? == false }
      if CArray.data_type?(:cmplx256)
        is_asserted_by {  CArray.cmplx256(1).boolean? == false }
      end
    end
    is_asserted_by {  CArray.object(1).boolean? == false }
  end

  example "numeric?" do
    is_asserted_by {  CArray.new(CA_FIXLEN, [1], bytes: 1).integer? == false }
    is_asserted_by {  CArray.boolean(1).integer? == false }
    is_asserted_by {  CArray.int8(1).integer? == true }
    is_asserted_by {  CArray.uint8(1).integer? == true }
    is_asserted_by {  CArray.int16(1).integer? == true }
    is_asserted_by {  CArray.uint16(1).integer? == true }
    is_asserted_by {  CArray.int32(1).integer? == true }
    is_asserted_by {  CArray.uint32(1).integer? == true }
    is_asserted_by {  CArray.int64(1).integer? == true }
    is_asserted_by {  CArray.uint64(1).integer? == true }
    is_asserted_by {  CArray.float32(1).integer? == false }
    is_asserted_by {  CArray.float64(1).integer? == false }
    if CArray.data_type?(:float128)
      is_asserted_by {  CArray.float128(1).integer? == false }
    end
    if CArray::HAVE_COMPLEX
      is_asserted_by {  CArray.cmplx64(1).integer? == false }
      is_asserted_by {  CArray.cmplx128(1).integer? == false }
      if CArray.data_type?(:cmplx256)
        is_asserted_by {  CArray.cmplx256(1).integer? == false }
      end
    end
    is_asserted_by {  CArray.object(1).integer? == false }
  end

  example "integer?" do
    is_asserted_by {  CArray.new(CA_FIXLEN, [1], bytes: 1).integer? == false }
    is_asserted_by {  CArray.boolean(1).integer? == false }
    is_asserted_by {  CArray.int8(1).integer? == true }
    is_asserted_by {  CArray.uint8(1).integer? == true }
    is_asserted_by {  CArray.int16(1).integer? == true }
    is_asserted_by {  CArray.uint16(1).integer? == true }
    is_asserted_by {  CArray.int32(1).integer? == true }
    is_asserted_by {  CArray.uint32(1).integer? == true }
    is_asserted_by {  CArray.int64(1).integer? == true }
    is_asserted_by {  CArray.uint64(1).integer? == true }
    is_asserted_by {  CArray.float32(1).integer? == false }
    is_asserted_by {  CArray.float64(1).integer? == false }
    if CArray.data_type?(:float128)
      is_asserted_by {  CArray.float128(1).integer? == false }
    end
    if CArray::HAVE_COMPLEX
      is_asserted_by {  CArray.cmplx64(1).integer? == false }
      is_asserted_by {  CArray.cmplx128(1).integer? == false }
      if CArray.data_type?(:cmplx256)
        is_asserted_by {  CArray.cmplx256(1).integer? == false }
      end
    end
    is_asserted_by {  CArray.object(1).integer? == false }
  end

  example "unsigned?" do
    is_asserted_by {  CArray.new(CA_FIXLEN, [1], bytes: 1).unsigned? == false }
    is_asserted_by {  CArray.boolean(1).unsigned? == false }
    is_asserted_by {  CArray.int8(1).unsigned? == false }
    is_asserted_by {  CArray.uint8(1).unsigned? == true }
    is_asserted_by {  CArray.int16(1).unsigned? == false }
    is_asserted_by {  CArray.uint16(1).unsigned? == true }
    is_asserted_by {  CArray.int32(1).unsigned? == false }
    is_asserted_by {  CArray.uint32(1).unsigned? == true }
    is_asserted_by {  CArray.int64(1).unsigned? == false }
    is_asserted_by {  CArray.uint64(1).unsigned? == true }
    is_asserted_by {  CArray.float32(1).unsigned? == false }
    is_asserted_by {  CArray.float64(1).unsigned? == false }
    if CArray.data_type?(:float128)
      is_asserted_by {  CArray.float128(1).unsigned? == false }
    end
    if CArray::HAVE_COMPLEX
      is_asserted_by {  CArray.cmplx64(1).unsigned? == false }
      is_asserted_by {  CArray.cmplx128(1).unsigned? == false }
      if CArray.data_type?(:cmplx256)
        is_asserted_by {  CArray.cmplx256(1).unsigned? == false }
      end
    end
    is_asserted_by {  CArray.object(1).unsigned? == false }
  end

  example "float?" do
    is_asserted_by {  CArray.new(CA_FIXLEN, [1], bytes: 1).float? == false }
    is_asserted_by {  CArray.boolean(1).float? == false }
    is_asserted_by {  CArray.int8(1).float? == false }
    is_asserted_by {  CArray.uint8(1).float? == false }
    is_asserted_by {  CArray.int16(1).float? == false }
    is_asserted_by {  CArray.uint16(1).float? == false }
    is_asserted_by {  CArray.int32(1).float? == false }
    is_asserted_by {  CArray.uint32(1).float? == false }
    is_asserted_by {  CArray.int64(1).float? == false }
    is_asserted_by {  CArray.uint64(1).float? == false }
    is_asserted_by {  CArray.float32(1).float? == true }
    is_asserted_by {  CArray.float64(1).float? == true }
    if CArray.data_type?(:float128)
      is_asserted_by {  CArray.float128(1).float? == true }
    end
    if CArray::HAVE_COMPLEX
      is_asserted_by {  CArray.cmplx64(1).float? == false }
      is_asserted_by {  CArray.cmplx128(1).float? == false }
      if CArray.data_type?(:cmplx256)
        is_asserted_by {  CArray.cmplx256(1).float? == false }
      end
    end
    is_asserted_by {  CArray.object(1).float? == false }
  end

  example "complex?" do
    is_asserted_by {  CArray.new(CA_FIXLEN, [1], bytes: 1).complex? == false }
    is_asserted_by {  CArray.boolean(1).complex? == false }
    is_asserted_by {  CArray.int8(1).complex? == false }
    is_asserted_by {  CArray.uint8(1).complex? == false }
    is_asserted_by {  CArray.int16(1).complex? == false }
    is_asserted_by {  CArray.uint16(1).complex? == false }
    is_asserted_by {  CArray.int32(1).complex? == false }
    is_asserted_by {  CArray.uint32(1).complex? == false }
    is_asserted_by {  CArray.int64(1).complex? == false }
    is_asserted_by {  CArray.uint64(1).complex? == false }
    is_asserted_by {  CArray.float32(1).complex? == false }
    is_asserted_by {  CArray.float64(1).complex? == false }
    if CArray.data_type?(:float128)
      is_asserted_by {  CArray.float128(1).complex? == false }
    end
    if CArray::HAVE_COMPLEX
      is_asserted_by {  CArray.cmplx64(1).complex? == true }
      is_asserted_by {  CArray.cmplx128(1).complex? == true }
      if CArray.data_type?(:cmplx256)
        is_asserted_by {  CArray.cmplx256(1).complex? == true }
      end
    end
    is_asserted_by {  CArray.object(1).complex? == false }
  end

  example "object?" do
    is_asserted_by {  CArray.new(CA_FIXLEN, [1], bytes: 1).object? == false }
    is_asserted_by {  CArray.boolean(1).object? == false }
    is_asserted_by {  CArray.int8(1).object? == false }
    is_asserted_by {  CArray.uint8(1).object? == false }
    is_asserted_by {  CArray.int16(1).object? == false }
    is_asserted_by {  CArray.uint16(1).object? == false }
    is_asserted_by {  CArray.int32(1).object? == false }
    is_asserted_by {  CArray.uint32(1).object? == false }
    is_asserted_by {  CArray.int64(1).object? == false }
    is_asserted_by {  CArray.uint64(1).object? == false }
    is_asserted_by {  CArray.float32(1).object? == false }
    is_asserted_by {  CArray.float64(1).object? == false }
    if CArray.data_type?(:float128)
      is_asserted_by {  CArray.float128(1).object? == false }
    end
    if CArray::HAVE_COMPLEX
      is_asserted_by {  CArray.cmplx64(1).object? == false }
      is_asserted_by {  CArray.cmplx128(1).object? == false }
      if CArray.data_type?(:cmplx256)
        is_asserted_by {  CArray.cmplx256(1).object? == false }
      end
    end
    is_asserted_by {  CArray.object(1).object? == true }
  end

  example "entity?" do
    a = CArray.int32(3)
    is_asserted_by {  a.entity? == true }
    is_asserted_by {  a[].entity? == false }
    is_asserted_by {  a[0..1].entity? == false }
    is_asserted_by {  a[a > 0].entity? == false }

    b = CScalar.int32()
    is_asserted_by {  b.entity? == true }
    is_asserted_by {  b[].entity? == true }
  end

  example "virtual?" do
    a = CArray.int32(3)
    is_asserted_by {  a.virtual? == false }
    is_asserted_by {  a[].virtual? == true }
    is_asserted_by {  a[0..1].virtual? == true }
    is_asserted_by {  a[a > 0].virtual? == true }

    b = CScalar.int32()
    is_asserted_by {  b.virtual? == false }
    is_asserted_by {  b[].virtual? == false }
  end

  example "valid_index?" do
    a = CArray.int32(3,3)
    is_asserted_by {  true == a.valid_index?(2, 2) }
    is_asserted_by {  true == a.valid_index?(1, 1) }
    is_asserted_by {  true == a.valid_index?((-1), (-1)) }
    is_asserted_by {  true == a.valid_index?((-3), (-3)) }

    is_asserted_by {  true == a.valid_addr?(8) }
    is_asserted_by {  true == a.valid_addr?(4) }
    is_asserted_by {  true == a.valid_addr?((-4)) }
    is_asserted_by {  true == a.valid_addr?((-8)) }
      
    is_asserted_by {  false == a.valid_index?(1, 3) }
    is_asserted_by {  false == a.valid_index?((-4), 1) }

    is_asserted_by {  false == a.valid_addr?(9) }
    is_asserted_by {  false == a.valid_addr?((-10)) }
  end

  example "same_shape?" do
    a = CArray.int32(4,3,2,1)
    b = CArray.int8(1,2,3,4)
    is_asserted_by {  false == a.same_shape?(b) }
    is_asserted_by {  true == a.transposed.same_shape?(b) }
  end

end

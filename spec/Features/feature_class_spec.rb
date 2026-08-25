
require 'carray'
require "rspec-power_assert"

describe "TestCArrayClass " do

  # CA_BIG_ENDIAN : 1
  # CA_LITTLE_ENDIAN : 0

  example "endian" do
    if [1].pack("s") == [1].pack("n")
      endian = CA_BIG_ENDIAN
    else
      endian = CA_LITTLE_ENDIAN
    end
    is_asserted_by {  CArray.endian == endian }
    case endian
    when CA_BIG_ENDIAN
      is_asserted_by {  CArray.big_endian? == true }
      is_asserted_by {  CArray.little_endian? == false }
    when CA_LITTLE_ENDIAN
      is_asserted_by {  CArray.big_endian? == false }
      is_asserted_by {  CArray.little_endian? == true }
    end
  end

  example "sizeof" do
    is_asserted_by {  CArray.sizeof(CA_INT8) == 1 }
    is_asserted_by {  CArray.sizeof(CA_UINT8) == 1 }
    is_asserted_by {  CArray.sizeof(CA_INT16) == 2 }
    is_asserted_by {  CArray.sizeof(CA_UINT16) == 2 }
    is_asserted_by {  CArray.sizeof(CA_INT32) == 4 }
    is_asserted_by {  CArray.sizeof(CA_UINT32) == 4 }
    # is_asserted_by { CArray.sizeof(CA_INT64), 8)
    # is_asserted_by { CArray.sizeof(CA_UINT64), 8)
    is_asserted_by {  CArray.sizeof(CA_FLOAT32) == 4 }
    is_asserted_by {  CArray.sizeof(CA_FLOAT64) == 8 }
    # is_asserted_by { CArray.sizeof(CA_CMPLX64), 8)
    # is_asserted_by { CArray.sizeof(CA_CMPLX128), 16)
    is_asserted_by {  CArray.sizeof(CA_FIXLEN) == 0 }
    # is_asserted_by { CArray.sizeof(CA_OBJECT), 0)
  end

  example "type_name" do
    [
     [CA_INT8, "int8"],
     [CA_UINT8, "uint8"],
     [CA_INT16, "int16"],
     [CA_UINT16, "uint16"],
     [CA_INT32, "int32"],
     [CA_UINT32, "uint32"],
     [CA_INT64, "int64"],
     [CA_UINT64, "uint64"],
     [CA_FLOAT32, "float32"],
     [CA_FLOAT64, "float64"],
     [CA_CMPLX64, "cmplx64"],
     [CA_CMPLX128, "cmplx128"],
     [CA_FIXLEN, "fixlen"],
     [CA_OBJECT, "object"],
    ].each do |type, name|
      is_asserted_by {  CArray.data_type_name(type) == name }
    end
  end

end

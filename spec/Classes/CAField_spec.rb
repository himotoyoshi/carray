
require 'carray'
require "rspec-power_assert"

describe "TestCArrayCAField " do

  example "virtual_array" do
    a = CArray.int(3,3)
    b = a.field(0,CA_INT8)
    r = b.parent
    is_asserted_by { b.class == CAField }
    is_asserted_by { true == b.virtual? }
    is_asserted_by { a == r }
  end

  example "attributes" do
    #
    a = CArray.int16(3,3) { 0x1122 }
    b = a.field(0, CA_INT8)
    is_asserted_by { CA_INT8 == b.data_type }
    is_asserted_by { [3, 3] == b.dim }
  end

  example "endian" do
    #
    a = CArray.int16(3,3) { 0x1122 }
    b = CArray.int8(3,3) { 0x11 }
    c = CArray.int8(3,3) { 0x22 }
    if CArray.big_endian?
      is_asserted_by { b == a.field(0, CA_INT8) }
      is_asserted_by { c == a.field(1, CA_INT8) }
    else
      is_asserted_by { b == a.field(1, CA_INT8) }
      is_asserted_by { c == a.field(0, CA_INT8) }
    end
  end


end


require 'carray'
require "rspec-power_assert"

describe "TestCArrayCreation " do

  example "s_new_uint8" do
    # ---
    ca = CArray.new(CA_UINT8, [3, 2, 1]) 
    is_asserted_by { ca.class == CArray }
    is_asserted_by { CA_UINT8 == ca.data_type }
    is_asserted_by { [3, 2, 1] == ca.dim }

    # ---
    ca = CArray.new(:uint8, [3, 2, 1]) 
    is_asserted_by { ca.class == CArray }
    is_asserted_by { CA_UINT8 == ca.data_type }
    is_asserted_by { [3, 2, 1] == ca.dim }

    # ---
    ca = CArray.uint8(3, 2, 1) 
    is_asserted_by { ca.class == CArray }
    is_asserted_by { CA_UINT8 == ca.data_type }
    is_asserted_by { [3, 2, 1] == ca.dim }
  end

  example "s_new_fixlen" do
    # ---
    ca = CArray.new(CA_FIXLEN, [3, 2, 1], :bytes=>10) 
    is_asserted_by { ca.class == CArray }
    is_asserted_by { CA_FIXLEN == ca.data_type }
    is_asserted_by { 10 == ca.bytes }
    is_asserted_by { [3, 2, 1] == ca.dim }

    # ---
    ca = CArray.new(:fixlen, [3, 2, 1], :bytes=>10) 
    is_asserted_by { ca.class == CArray }
    is_asserted_by { CA_FIXLEN == ca.data_type }
    is_asserted_by { 10 == ca.bytes }
    is_asserted_by { [3, 2, 1] == ca.dim }

    # ---
    ca = CArray.fixlen(3, 2, 1, :bytes=>10) 
    is_asserted_by { ca.class == CArray }
    is_asserted_by { CA_FIXLEN == ca.data_type }
    is_asserted_by { 10 == ca.bytes }
    is_asserted_by { [3, 2, 1] == ca.dim }
  end

  example "s_new_various_types" do
    # ---
    data_type_list = [
      CA_BOOLEAN,
      CA_UINT8, CA_INT8,
      CA_UINT16, CA_INT16,
      CA_UINT32, CA_INT32,
      CA_FLOAT32, CA_FLOAT64,
      CA_OBJECT
    ]
    data_type_list.each do |type|
      ca = CArray.new(type, [3, 2, 1]) 
      is_asserted_by { ca.class == CArray }
      is_asserted_by { type == ca.data_type }
    end    

    # ---
    data_type_name_list = [
      "boolean",
      "uint8", "int8",
      "uint16", "int16",
      "uint32", "int32",
      "float32", "float64",
      "object"
    ]
    data_type_name_list.each do |type|
      ca = CArray.send(type, 3, 2, 1) 
      is_asserted_by { ca.class == CArray }
      is_asserted_by { type == ca.data_type_name }
    end

  end


end

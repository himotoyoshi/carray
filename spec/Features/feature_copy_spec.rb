require "carray"
require 'rspec-power_assert'

describe "Feature: Copying" do

  example "to_ca" do
    #
    a = CArray.int32(3,3).seq
    b = a.to_ca
    is_asserted_by { CA_INT32([ [ 0, 1, 2 ],
                            [ 3, 4, 5 ],
                            [ 6, 7, 8 ] ]) == a }
    is_asserted_by { a == b }

    # mask does not be templated
    a = CArray.int32(3,3).seq
    a[1,1] = UNDEF
    b = a.to_ca
    is_asserted_by { CA_INT32([ [ 0, 1, 2 ],
                            [ 3, UNDEF, 5 ],
                            [ 6, 7, 8 ] ]) == a }
    is_asserted_by { a == b }
  end

  example "template" do
    #
    a = CArray.int32(3,3).seq
    b = a.template {1}
    is_asserted_by { CA_INT32([ [ 0, 1, 2 ],
                            [ 3, 4, 5 ],
                            [ 6, 7, 8 ] ]) == a }
    is_asserted_by { CA_INT32([ [ 1, 1, 1 ],
                            [ 1, 1, 1 ],
                            [ 1, 1, 1 ] ]) == b }

    # mask does not be templated
    a = CArray.int32(3,3).seq
    a[1,1] = UNDEF
    b = a.template {1}
    is_asserted_by { CA_INT32([ [ 0, 1, 2 ],
                            [ 3, UNDEF, 5 ],
                            [ 6, 7, 8 ] ]) == a }
    is_asserted_by { CA_INT32([ [ 1, 1, 1 ],
                            [ 1, 1, 1 ],
                            [ 1, 1, 1 ] ]) == b }
  end

  example "to_type" do
    #
    a = CArray.int8(3,3).seq
    b = a.int32
    is_asserted_by { CA_INT8([ [ 0, 1, 2 ],
                           [ 3, 4, 5 ],
                           [ 6, 7, 8 ] ]) == a }
    is_asserted_by { CA_INT32([ [ 0, 1, 2 ],
                            [ 3, 4, 5 ],
                            [ 6, 7, 8 ] ]) == b }


    #
    a = CArray.int8(3,3).seq
    a[1,1] = UNDEF
    b = a.int32
    is_asserted_by { CA_INT8([ [ 0, 1, 2 ],
                           [ 3, UNDEF, 5 ],
                           [ 6, 7, 8 ] ]) == a }
    is_asserted_by { CA_INT32([ [ 0, 1, 2 ],
                            [ 3, UNDEF, 5 ],
                            [ 6, 7, 8 ] ]) == b }
  end

  example "convert" do
    #
    a = CArray.int8(3,3).seq
    b = a.convert(CA_INT32) {|x| 2*x}
    is_asserted_by { CA_INT8([ [ 0, 1, 2 ],
                           [ 3, 4, 5 ],
                           [ 6, 7, 8 ] ]) == a }
    is_asserted_by { CA_INT32([ [ 0, 2, 4 ],
                            [ 6, 8, 10 ],
                            [ 12, 14, 16 ] ]) == b }

    #
    a = CArray.int8(3,3).seq
    a[1,1] = UNDEF
    b = a.convert(CA_INT32) {|x| 2 * x }
    is_asserted_by { CA_INT8([ [ 0, 1, 2 ],
                           [ 3, UNDEF, 5 ],
                           [ 6, 7, 8 ] ]) == a }
    is_asserted_by { CA_INT32([ [ 0, 2, 4 ],
                            [ 6, UNDEF, 10 ],
                            [ 12, 14, 16 ] ]) == b }
  end

  example "transform" do
    #
    a = CArray.uint8(2,4) { 0xff }
    b = a.refer(CA_UINT16, [2,2]).to_ca
    is_asserted_by { CA_UINT8([ [ 255, 255, 255, 255 ],
                            [ 255, 255, 255, 255 ] ]) == a }
    is_asserted_by { CA_UINT16([ [ 65535, 65535 ],
                             [ 65535, 65535 ] ]) == b }
  end

  example "to_a" do
    #
    a = CArray.int32(3,3).seq
    b = a.to_a
    is_asserted_by { [ [ 0, 1, 2 ],
                   [ 3, 4, 5 ],
                   [ 6, 7, 8 ] ] == b }

    # mask does not be templated
    a = CArray.int32(3,3).seq
    a[1,1] = UNDEF
    b = a.to_a
    is_asserted_by { [ [ 0, 1, 2 ],
                   [ 3, UNDEF, 5 ],
                   [ 6, 7, 8 ] ] == b }
  end


end

require "test/unit"

require "carray"

class TestCArrayCopy < Test::Unit::TestCase

  def test_to_ca
    #
    a = CArray.int32(3,3).seq
    b = a.to_ca
    assert_equal(CA_INT32([ [ 0, 1, 2 ],
                            [ 3, 4, 5 ],
                            [ 6, 7, 8 ] ]), a)
    assert_equal(a, b)

    # mask does not be templated
    a = CArray.int32(3,3).seq
    a[1,1] = UNDEF
    b = a.to_ca
    assert_equal(CA_INT32([ [ 0, 1, 2 ],
                            [ 3, UNDEF, 5 ],
                            [ 6, 7, 8 ] ]), a)
    assert_equal(a, b)
  end

  def test_template
    #
    a = CArray.int32(3,3).seq
    b = a.template {1}
    assert_equal(CA_INT32([ [ 0, 1, 2 ],
                            [ 3, 4, 5 ],
                            [ 6, 7, 8 ] ]), a)
    assert_equal(CA_INT32([ [ 1, 1, 1 ],
                            [ 1, 1, 1 ],
                            [ 1, 1, 1 ] ]), b)

    # mask does not be templated
    a = CArray.int32(3,3).seq
    a[1,1] = UNDEF
    b = a.template {1}
    assert_equal(CA_INT32([ [ 0, 1, 2 ],
                            [ 3, UNDEF, 5 ],
                            [ 6, 7, 8 ] ]), a)
    assert_equal(CA_INT32([ [ 1, 1, 1 ],
                            [ 1, 1, 1 ],
                            [ 1, 1, 1 ] ]), b)
  end

  def test_to_type
    #
    a = CArray.int8(3,3).seq
    b = a.int32
    assert_equal(CA_INT8([ [ 0, 1, 2 ],
                           [ 3, 4, 5 ],
                           [ 6, 7, 8 ] ]), a)
    assert_equal(CA_INT32([ [ 0, 1, 2 ],
                            [ 3, 4, 5 ],
                            [ 6, 7, 8 ] ]), b)


    #
    a = CArray.int8(3,3).seq
    a[1,1] = UNDEF
    b = a.int32
    assert_equal(CA_INT8([ [ 0, 1, 2 ],
                           [ 3, UNDEF, 5 ],
                           [ 6, 7, 8 ] ]), a)
    assert_equal(CA_INT32([ [ 0, 1, 2 ],
                            [ 3, UNDEF, 5 ],
                            [ 6, 7, 8 ] ]), b)
  end

  def test_convert
    #
    a = CArray.int8(3,3).seq
    b = a.convert(CA_INT32) {|x| 2*x}
    assert_equal(CA_INT8([ [ 0, 1, 2 ],
                           [ 3, 4, 5 ],
                           [ 6, 7, 8 ] ]), a)
    assert_equal(CA_INT32([ [ 0, 2, 4 ],
                            [ 6, 8, 10 ],
                            [ 12, 14, 16 ] ]), b)

    #
    a = CArray.int8(3,3).seq
    a[1,1] = UNDEF
    b = a.convert(CA_INT32) {|x| 2 * x }
    assert_equal(CA_INT8([ [ 0, 1, 2 ],
                           [ 3, UNDEF, 5 ],
                           [ 6, 7, 8 ] ]), a)
    assert_equal(CA_INT32([ [ 0, 2, 4 ],
                            [ 6, UNDEF, 10 ],
                            [ 12, 14, 16 ] ]), b)
  end

  def test_transform
    #
    a = CArray.uint8(2,4) { 0xff }
    b = a.refer(CA_UINT16, [2,2]).to_ca
    assert_equal(CA_UINT8([ [ 255, 255, 255, 255 ],
                            [ 255, 255, 255, 255 ] ]), a)
    assert_equal(CA_UINT16([ [ 65535, 65535 ],
                             [ 65535, 65535 ] ]), b)
  end

  def test_to_a
    #
    a = CArray.int32(3,3).seq
    b = a.to_a
    assert_equal([ [ 0, 1, 2 ],
                   [ 3, 4, 5 ],
                   [ 6, 7, 8 ] ], b)

    # mask does not be templated
    a = CArray.int32(3,3).seq
    a[1,1] = UNDEF
    b = a.to_a
    assert_equal([ [ 0, 1, 2 ],
                   [ 3, UNDEF, 5 ],
                   [ 6, 7, 8 ] ], b)
  end

  def test_map
    #
    a = CArray.int32(3,3).seq
    b = a.map{|x| x.to_s }
    b.to_a
    assert_equal([ [ "0", "1", "2" ],
                   [ "3", "4", "5" ],
                   [ "6", "7", "8" ] ], b)

    # mask does not be templated
    a = CArray.int32(3,3).seq
    a[1,1] = UNDEF
    b = a.map{|x| x.to_s }
    assert_equal([ [ "0", "1", "2" ],
                   [ "3", UNDEF, "5" ],
                   [ "6", "7", "8" ] ], b)
  end

end

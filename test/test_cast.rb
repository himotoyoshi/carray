require 'test/unit'
require 'carray'

class TestCast < Test::Unit::TestCase

  def test_obj_to_numeric
    # ---
    a = CA_OBJECT([1,2,3])
    b = CA_INT32([1,2,3])
    c = CA_FLOAT64([1,2,3])
    assert_equal(b, a.int32)
    assert_equal(c, a.float64)

    # ---
    a = CA_OBJECT(["1","2","3"])
    b = CA_INT32([1,2,3])
    c = CA_FLOAT64([1,2,3])
    assert_equal(b, a.int32)
    assert_equal(c, a.float64)

    # ---
    a = CA_OBJECT([nil, nil, nil])
    assert_raise(TypeError) { a.int32 }
#    assert_raise(TypeError) { a.float32 }

    # ---
    a = CA_OBJECT(["a", "b", "c"])
    assert_raise(ArgumentError) { a.int32 }
    assert_raise(ArgumentError) { a.float32 }
  end


end
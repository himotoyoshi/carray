#
# * scalar creation
# * scalar?
#
#
#

$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCScalar < Test::Unit::TestCase

  def test_s_new
    a = CScalar.int32 { 1 }
    assert_equal(true, a.scalar?)
    assert_equal(CA_INT32, a.data_type)
    assert_equal(1, a.rank)
    assert_equal(CArray.sizeof(CA_INT32), a.bytes)
    assert_equal([1], a.dim)
    assert_equal(1, a.elements)
    assert_equal(CA_INT32(1), a)
  end

  def test_ref_scalar
    a = CScalar.int32 { 0 }
    assert_equal(true, a.scalar?)
    assert_equal(true, a[].scalar?)
    assert_equal(true, a.refer(CA_UINT32).scalar?)
    assert_equal(true, a.fake(CA_UINT32).scalar?)
    assert_equal(true, a.field(0,CA_UINT32).scalar?)
    assert_equal(true, a[a].scalar?)
    assert_equal(true, a[a.eq(0)].scalar?)
    assert_equal(true, a[a.eq(1)].scalar?) 

    assert_equal(false, a[nil].scalar?)
  end

  def test_scalar_operation
    a = CScalar.int32 { 1 }
    b = CScalar.int32 { 2 }
    assert_instance_of(CScalar, -a)

    assert_instance_of(CScalar, a.add(b))
    assert_instance_of(CScalar, a + b)
    assert_instance_of(CScalar, a < b)

    assert_instance_of(CScalar, a.add(1))
    assert_instance_of(CScalar, a + 1)
    assert_instance_of(CScalar, a < 1)
  end

  def test_scalar_arith
    a = CScalar.int32 {1}

    a[] = 1
    a = a + 1
    assert_equal(2, a[0])

    a[] = 1
    a = 1 + a
    assert_equal(2, a[0])

    a[] = 1
    a = a - 1
    assert_equal(0, a[0])

    a[] = 1
    a = 1 - a
    assert_equal(0, a[0])

    a[] = 1
    a = 2*a
    assert_equal(2, a[0])

    a[] = 1
    a = a*2
    assert_equal(2, a[0])

    a[] = 4
    a = a/2
    assert_equal(2, a[0])

    a[] = 2
    a = 4/a
    assert_equal(2, a[0])

  end

end

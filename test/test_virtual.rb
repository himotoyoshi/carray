$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArrayVirtual < Test::Unit::TestCase

  def test_clone
    a = CArray.int(3,3)
    a[1,1] = UNDEF
    b = a[1..2,1..2]
    assert_equal(b, b.clone)
    assert_equal(b, b.clone.to_ca)
    assert_equal(b.mask, b.clone.mask)
    assert_not_equal(b.object_id, b.clone.object_id)
    assert_not_equal(b.mask.object_id, b.clone.mask.object_id)
  end

  def test_attached?
    a = CArray.int(10,10)
    r = a[]
    assert_equal(false, r.attached?)
    r.attach{
      assert_equal(true, r.attached?)
    }
    assert_equal(false, r.attached?)
    r.attach!{
      assert_equal(true, r.attached?)
    }
  end

  def test_root_array
    a = CArray.int(10,10).seq
    b = a[]
    c = b[0..5,nil]
    d = c[c > 50]
    e = d[d.address]
    assert_equal(a.object_id, b.root_array.object_id)
    assert_equal(a.object_id, c.root_array.object_id)
    assert_equal(a.object_id, d.root_array.object_id)
    assert_equal(a.object_id, e.root_array.object_id)
    assert_equal([a.object_id,
                  b.object_id,
                  c.object_id,
                  d.object_id,
                  e.object_id], e.ancestors.map{|x| x.object_id})
  end

end

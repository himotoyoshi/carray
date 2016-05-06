$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArrayCARepeat < Test::Unit::TestCase

  def test_virtual_array
    a = CArray.int(3)
    b = a[:%,3]
    r = b.parent
    assert_instance_of(CARepeat, b)
    assert_equal(true, b.virtual?)
    assert_equal(true, b.read_only?)
    assert_equal(false, b.attached?)
    assert_equal(a, r)
  end

  def test_basic_feature
    # ---
    a = CArray.int(3).seq!
    r1 = a[3,:%]
    r2 = a[:%,3]
    assert_equal(CA_INT([[0,1,2],
                         [0,1,2],
                         [0,1,2]]), r1)
    assert_equal(CA_INT([[0,0,0],
                         [1,1,1],
                         [2,2,2]]), r2)
    # ---
    b = CArray.int(2,2).seq!
    assert_equal(CA_INT([[[ 0, 1 ],
                          [ 0, 1 ]],
                         [[ 2, 3 ],
                          [ 2, 3 ]]]), b[:%,2,:%])
  end

  def test_store
    a = CArray.int(3).seq!
    r1 = a[3,:%]
    assert_raise(RuntimeError) { r1[1,1] = 1 }
    assert_raise(RuntimeError) { r1.seq! }    
    r2 = a[:%,3]
    assert_raise(RuntimeError) { r1[1,1] = 1 }
    assert_raise(RuntimeError) { r1.seq! }    
  end

  def test_mask_repeat
    a = CArray.int(3).seq!
    a[1] = UNDEF
    r1 = a[3,:%]
    x1 = r1.to_ca
    assert_equal(3, r1.count_masked)
    assert_equal(3, r1[nil,1].count_masked)
    assert_equal(3, x1.count_masked)
    assert_equal(3, x1[nil,1].count_masked)
    
    r2 = a[:%,3]
    x2 = r2.to_ca
    assert_equal(3, r2.count_masked)
    assert_equal(3, r2[1,nil].count_masked)
    assert_equal(3, x2.count_masked)
    assert_equal(3, x2[1,nil].count_masked)
  end

end

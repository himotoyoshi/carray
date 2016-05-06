$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArrayNArray < Test::Unit::TestCase

  def test_na
    a = CArray.int32(3, 3).seq!
    assert_equal(NArray.int(3,3).indgen!, a.na)
    assert_equal(NArray.int(9).indgen!, a.na(9))

    b = a.na
    assert_equal(a, b.ca)
    assert_equal(CArray.int(9).seq!, b.ca(9))
  end

  def test_to_na
    a = CArray.int32(3, 3).seq!
    assert_equal(NArray.int(3,3).indgen!, a.to_na)

    b = a.to_na
    assert_equal(a, b.to_ca)
  end

  def test_asign
    a = CArray.int32(3, 3) { 0 }
    b = NArray.int(3,3).indgen!
    a[] = b
    assert_equal(b.ca, a)
  end

  def test_empty_array

    na0  = NArray.int(0)
    ca0  = CArray.int(0)
    ca30 = CArray.int(3,0)

    #--- na
    assert_equal(na0, ca0.na)
    assert_equal(na0, ca30.na)

    #--- to_na
    assert_equal(na0, ca0.to_na)
    assert_equal(na0, ca30.to_na)

    #--- to_na!
    assert_equal(na0, ca0.to_na!)
    assert_equal(na0, ca30.to_na!)

    #--- ca
    assert_equal(ca0, na0.ca)

    #--- to_ca
    assert_equal(ca0, na0.to_ca)

    #--- to_ca!
    assert_equal(ca0, na0.to_ca!)
    assert_equal(na0, ca30.to_na!)

  end


end

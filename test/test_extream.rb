$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArrayExtream < Test::Unit::TestCase

  def test_zero_length_array
    # ---
    a = CArray.int(0)
    assert_equal(1, a.rank)
    assert_equal(0, a.elements)
    assert_equal([0], a.dim)
    assert_equal(0, a.dim0)

    # ---
    a = CArray.int(0, 3)
    assert_equal(2, a.rank)
    assert_equal(0, a.elements)
    assert_equal([0,3], a.dim)
    assert_equal(0, a.dim0)
    assert_equal(3, a.dim1)

    # ---
    a = CArray.int(3, 0)
    assert_equal(2, a.rank)
    assert_equal(0, a.elements)
    assert_equal([3,0], a.dim)
    assert_equal(3, a.dim0)
    assert_equal(0, a.dim1)
  end

  def test_zero_length_fixlen
    # ---
    assert_nothing_raised { CArray.new(CA_FIXLEN, [3,3], :bytes => 0) }
    assert_raise(RuntimeError){ CArray.new(CA_FIXLEN, [3,3], :bytes => -1) }
  end

  def test_large_rank_array
    # ---
    dim = [2] * (CA_RANK_MAX)
    assert_instance_of(CArray, CArray.int8(*dim))

    # ---
    dim = [2] * (CA_RANK_MAX+1)
    assert_raise(RuntimeError){ CArray.int8(*dim) }
  end

  def test_negative_dimension_size
    # ---
    assert_raise(RuntimeError){ CArray.int8(-1) }
    assert_raise(RuntimeError){ CArray.int8(-1, -1) }
  end

end

#$:.unshift("../lib", "..")

require 'test/unit'
require 'carray'

class TestCArrayGenerate < Test::Unit::TestCase

  def test_swap_bytes
    #
    a = CArray.int16(3,3) { 0x1234 }
    b = CArray.int16(3,3) { 0x3412 }
    assert_equal(b, a.swap_bytes)
    assert_equal(a, b.swap_bytes)
    assert_equal(a, a.swap_bytes.swap_bytes)

    #
    a = CArray.int32(3,3) { 0x12345678 }
    b = CArray.int32(3,3) { 0x78563412 }
    assert_equal(b, a.swap_bytes)
    assert_equal(a, b.swap_bytes)
    assert_equal(a, a.swap_bytes.swap_bytes)

    #
    if CArray::HAVE_COMPLEX
      c = CArray.int32(1) { 0x12345678 }
      x = c.refer(CA_FLOAT32, [1])[0]
      y = c.swap_bytes.refer(CA_FLOAT32, [1])[0]
      a = CArray.complex(3,3) { x + y*CI }
      b = CArray.complex(3,3) { y + x*CI }
      assert_equal(b, a.swap_bytes)
      assert_equal(a, b.swap_bytes)
      assert_equal(a, a.swap_bytes.swap_bytes)
    end
  end

  def test_seq
    # ---
    a = CArray.object(3).seq!
    assert_equal(CA_OBJECT([0,1,2]), a)

    # ---
    a = CArray.object(3).seq!(1)
    assert_equal(CA_OBJECT([1,2,3]), a)

    # ---
    a = CArray.object(3).seq!(1,2)
    assert_equal(CA_OBJECT([1,3,5]), a)

    # ---
    a = CArray.object(3).seq!(3,-1)
    assert_equal(CA_OBJECT([3,2,1]), a)

    # ---
    a = CArray.object(3).seq!("a", "a")
    assert_equal(CA_OBJECT(["a", "aa", "aaa"]), a)

    # ---
    a = CArray.object(3).seq!("a", :succ)
    assert_equal(CA_OBJECT(["a", "b", "c"]), a)

    # ---
    a = CArray.object(3).seq!("a", :succ) { |x| "@" + x }
    assert_equal(CA_OBJECT(["@a", "@b", "@c"]), a)

    # ---
    a = CArray.object(3).seq!("a", :succ)
    assert_equal(CA_OBJECT(["@a", "@b", "@c"]), CA_OBJECT("@") + a)

    # ---
    a = CArray.object(3).seq!([], [nil])
    assert_equal(CA_OBJECT([[], [nil], [nil, nil]]), a)
  end


end

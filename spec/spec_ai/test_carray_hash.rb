require "test/unit"
require "carray"

# a.eql?(b) implies a.hash == b.hash, so equal arrays find each other as
# Hash keys.
class TestCArrayHash < Test::Unit::TestCase

  def assert_same_key (a, b)
    assert_true a.eql?(b)
    assert_equal a.hash, b.hash
    assert_equal :found, { a => :found }[b]
  end

  # eql? compares object cells with #eql?, so equal objects in distinct
  # cells hash alike.
  def test_object_arrays_of_equal_elements
    assert_same_key CA_OBJECT(["ab", "cd"]), CA_OBJECT(["ab", "cd"])
    assert_same_key CA_OBJECT([1, 2.5, :x]), CA_OBJECT([1, 2.5, :x])
    assert_not_equal CA_OBJECT(["ab", "cd"]).hash, CA_OBJECT(["ab", "ce"]).hash
  end

  def test_numeric_arrays
    assert_same_key CA_INT32([1, 2, 3]), CA_INT32([1, 2, 3])
    assert_same_key CA_FLOAT64([Float::NAN]), CA_FLOAT64([Float::NAN])
  end

  def test_a_view_hashes_as_the_entity_it_equals
    base = CArray.int32(10).seq
    assert_same_key base[2..5], CA_INT32([2, 3, 4, 5])
    objs = CArray.object(6) { |i| "s#{i}" }
    assert_same_key objs[(0...6).step(2)], CA_OBJECT(["s0", "s2", "s4"])
  end
end

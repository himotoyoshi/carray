require "test/unit"
require "carray"

# An inherit_mask source is read cell by cell over the receiver.  A larger
# one was accepted and its first cells read.
class TestInheritMaskSourceSize < Test::Unit::TestCase

  def test_a_larger_source_is_refused
    a = CA_INT32([1, 2, 3])
    s = CA_INT32([1, 2, 3, 4, 5])
    assert_raise(ArgumentError) { a.inherit_mask(s) }
    assert_raise(ArgumentError) { a.inherit_mask_replace(s) }
    assert_raise(ArgumentError) { a.inherit_mask(CA_INT32([1, 2])) }
  end

  def test_same_size_and_scalar_sources
    a = CA_INT32([1, 2, 3])
    m = CA_INT32([1, 2, 3])
    m[1] = UNDEF
    a.inherit_mask(m)
    assert_equal [1, UNDEF, 3], a.to_a
    b = CA_INT32([1, 2, 3])
    b.inherit_mask(CScalar.new(:int32))
    assert_equal [1, 2, 3], b.to_a
  end

end

$LOAD_PATH.unshift File.expand_path('../../ext', __dir__)
$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'carray'
require 'test/unit'

# A store of a whole array opens its target to be written only, which
# clears the mask; when the conversion raises part way, the mask comes
# back as it was.

class TestAllocateWindowKeepsMask < Test::Unit::TestCase

  def test_entity
    m = CA_INT32([1, UNDEF, 3])
    assert_raise(FloatDomainError) { m[] = CA_FLOAT64([1, Float::NAN, 2]) }
    assert_equal [false, true, false], m.is_masked.to_a
  end

  def test_view_keeps_the_parents_mask
    v = CA_INT32([1, UNDEF, 3, 4])
    assert_raise(FloatDomainError) { v[0..2][] = CA_FLOAT64([1, Float::NAN, 2]) }
    assert_equal [false, true, false, false], v.is_masked.to_a
  end

  def test_a_store_that_completes_still_clears_the_mask
    m = CA_INT32([1, UNDEF, 3])
    m[] = CA_FLOAT64([7, 8, 9])
    assert_equal [7, 8, 9], m.to_a
  end

end

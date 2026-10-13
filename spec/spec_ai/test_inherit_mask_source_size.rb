# ----------------------------------------------------------------------------
#
#  spec_ai/test_inherit_mask_source_size.rb
#
#  inherit_mask ORs each source's mask cell by cell into the receiver's, so
#  an array source must have a cell for every cell of the receiver.  A
#  scalar source applies its one mask cell to all of them.
#
# ----------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestInheritMaskSourceSize < Test::Unit::TestCase

  def test_a_smaller_array_source_is_refused
    d = CArray.float64(100)
    s = CArray.float64(4)
    s[1] = UNDEF
    assert_raise(ArgumentError) { d.inherit_mask(s) }
    assert_equal false, d.has_mask?
    assert_equal 0, d.count_masked
    assert_raise(ArgumentError) { d.inherit_mask_replace(s) }
  end

  def test_a_smaller_source_without_a_mask_is_refused
    d = CArray.float64(10)
    assert_raise(ArgumentError) { d.inherit_mask(CArray.float64(4)) }
  end

  def test_a_source_of_the_same_size_is_taken
    d = CArray.float64(4)
    s = CArray.float64(4)
    s[1] = UNDEF
    d.inherit_mask(s)
    assert_equal [false, true, false, false], d.is_masked.to_a
  end

  def test_a_masked_scalar_source_masks_every_cell
    d = CArray.float64(3)
    s = CScalar.new(CA_FLOAT64)
    s[0] = UNDEF
    d.inherit_mask(s)
    assert_equal [true, true, true], d.is_masked.to_a
  end

end

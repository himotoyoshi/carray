# dup / clone of a view is another view onto the same parent (Ruby's shallow
# copy), rebuilt by its class.  What the original was told about itself must
# survive that: a value array still cannot hold a mask, a read-only view is
# still read-only, and clone of a frozen array is read-only as well.

require "test/unit"
require "carray"

class TestDupCloneKeepState < Test::Unit::TestCase

  def masked
    x = CA_FLOAT64([1, 2, 3])
    x[1] = UNDEF
    x
  end

  def test_value_array_dup_cannot_mask_the_source
    x = masked
    %i[dup clone].each do |m|
      [x.value, x.value.reshape(3)].each do |v|
        d = v.send(m)
        assert_equal true,  d.value_array?
        assert_equal false, d.has_mask?
        assert_equal [1.0, 2.0, 3.0], d.to_a
        assert_raise(TypeError) { d[0] = UNDEF }
      end
    end
    assert_equal [1.0, UNDEF, 3.0], x.to_a
  end

  def test_read_only_view_dup_stays_read_only
    x = CA_INT32([1, 2, 3])
    b = x[:_, nil].broadcast_to(2, 3)
    [b.dup, b.clone, b[0, nil].dup, b.reshape(2, 3, 1).dup].each do |d|
      assert_equal true, d.read_only?
      assert_raise(RuntimeError) { d[0] = 9 }
    end
    assert_equal [1, 2, 3], x.to_a
  end

  def test_clone_of_frozen_is_read_only
    x = CArray.float64(3).seq!
    x.freeze
    assert_equal true,  x.clone.read_only?
    assert_equal false, x.clone(freeze: false).read_only?
    assert_equal false, x.dup.read_only?
  end

  def test_dup_of_masked_view_keeps_its_mask
    x = masked
    d = x[0..2].dup
    assert_equal [false, true, false], d.mask.to_a
    d[0] = 10
    assert_equal 10.0, x[0]
  end
end

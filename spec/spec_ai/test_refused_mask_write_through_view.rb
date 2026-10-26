require 'test/unit'
require 'carray'

# A mask write refused because it would put a true into the part of a stack
# or meld that can have no mask (a value array or a mask array) changes no
# part, also when it reaches the stack or meld through another view that
# hands the write on in several pieces.
class TestRefusedMaskWriteThroughView < Test::Unit::TestCase

  def parts
    a = CArray.float64(3).seq(1)
    a[1] = UNDEF
    b = CArray.float64(3).seq(1)
    [a, b]
  end

  def refused_and_unchanged (b, name)
    before_values = b.value.to_a
    before_mask   = b.has_mask? ? b.is_masked.to_a : nil
    assert_raise(TypeError, name) { yield }
    assert_equal before_values, b.value.to_a, name
    assert_equal before_mask, (b.has_mask? ? b.is_masked.to_a : nil), name
  end

  def test_grid_over_a_stack_with_a_value_array_part
    writes = {
      "store UNDEF"    => ->(s) { s[CA_INT([0, 1]), nil] = UNDEF },
      "mask ="         => ->(s) { s[CA_INT([0, 1]), nil].mask = 1 },
      "fill"           => ->(s) { s[CA_INT([0, 1]), nil].fill(UNDEF) },
      "mask of stack"  => ->(s) { s.mask[CA_INT([0, 1]), nil] = 1 },
      "grid of block"  => ->(s) { s[0..1, nil][CA_INT([0, 1]), nil] = UNDEF },
    }
    writes.each do |name, write|
      [false, true].each do |b_masked|
        next if name == "mask of stack" && ! b_masked   # no part has a mask: s.mask is 0
        a, b = parts
        b[2] = UNDEF if b_masked
        s = CArray.stack([b, a.value])
        refused_and_unchanged(b, "#{name} (b masked: #{b_masked})") { write.call(s) }
      end
    end
  end

  def test_grid_over_a_stack_with_a_mask_array_part
    a, = parts
    c = CArray.boolean(3)
    c[] = 1
    s = CArray.stack([c, a.mask])
    refused_and_unchanged(c, "mask array part") { s[CA_INT([0, 1]), nil] = UNDEF }
  end

  def test_grid_over_a_meld_with_a_value_array_part
    a = CArray.float64(2, 3).seq(1)
    a[1, 1] = UNDEF
    b = CArray.float64(2, 3).seq(1)
    m = CArray.meld(b, a.value, axis: 0)
    refused_and_unchanged(b, "meld, grid on axis 0") { m[CA_INT([0, 3]), nil] = UNDEF }
  end

  # The write that touches only the parts that can have a mask goes through.
  def test_a_write_into_the_maskable_part_only_goes_through
    a, b = parts
    s = CArray.stack([b, a.value])
    s[CA_INT([0]), nil] = UNDEF
    assert_equal [UNDEF, UNDEF, UNDEF], b.to_a
  end

  # The inner stack has no mask yet: the outer one reads a stand-in for it,
  # and the write reaches the inner stack's parts only when it settles.
  def test_a_stack_inside_a_stack
    writes = {
      "boolean"   => ->(s) { s[s.value.gt(0)] = UNDEF },
      "method"    => ->(s) { s[:gt, 0] = UNDEF },
      "whole"     => ->(s) { s[] = UNDEF },
      "fill"      => ->(s) { s.fill(UNDEF) },
    }
    writes.each do |name, write|
      [:inner_first, :inner_last].each do |order|
        a, b = parts
        c = CArray.float64(2, 3).seq(1)
        inner = CArray.stack([b, a.value])
        s = order == :inner_first ? CArray.stack([inner, c]) : CArray.stack([c, inner])
        refused_and_unchanged(b, "#{name} #{order}: b") { write.call(s) }
        assert_equal false, c.has_mask?, "#{name} #{order}: c"
        assert_equal false, inner.has_mask?, "#{name} #{order}: inner"
      end
    end
  end

  def test_a_meld_inside_a_stack
    a, b = parts
    inner = CArray.meld(b, a.value, axis: 0)
    s = CArray.stack([inner, CArray.float64(6).seq])
    refused_and_unchanged(b, "meld in stack") { s[s.value.gt(0)] = UNDEF }
  end

  # A write into the inner stack's part that can take a mask goes through.
  def test_a_write_into_the_maskable_part_of_an_inner_stack_goes_through
    a, b = parts
    s = CArray.stack([CArray.stack([b, a.value]), CArray.float64(2, 3)])
    s[0, 0, nil] = UNDEF
    assert_equal [UNDEF, UNDEF, UNDEF], b.to_a
  end
end

# spec_ai/test_multi_parent_shared_cells.rb
#
# A stack or meld whose parts share cells (the same array twice, or two
# views of it) takes, in each shared cell, the write of the last part that
# covers it -- for values and for the mask, whatever kind of view a part
# is, and whether or not the array had a mask before.

require "test/unit"
require "carray"

class TestMultiParentSharedCells < Test::Unit::TestCase

  PARTS = {
    "itself"            => ->(a) { a },
    "fake"              => ->(a) { a.fake(:uint32).fake(:int32) },
    "two byte swaps"    => ->(a) { a.swap_bytes.swap_bytes },
    "cast over a cast"  => ->(a) { CArray.wrap_writable(CArray.wrap_writable(a, CA_INT64), CA_INT32) },
  }

  def test_values_take_the_last_part
    PARTS.each do |name, part|
      [:stack, :meld].each do |kind|
        a = CArray.int32(4).seq
        v = kind == :stack ? CArray.stack([part.call(a), a]) : CArray.meld(part.call(a), a)
        v.add!(CA_INT32([1, 2, 3, 4, 10, 20, 30, 40]).reshape(*v.shape))
        assert_equal [10, 21, 32, 43], a.to_a, "#{kind} of #{name} and itself"
        a = CArray.int32(4).seq
        v = kind == :stack ? CArray.stack([part.call(a), a]) : CArray.meld(part.call(a), a)
        v.map! { |x| x + 1 }
        v[] = CA_INT32([1, 2, 3, 4, 10, 20, 30, 40]).reshape(*v.shape)
        assert_equal [10, 20, 30, 40], a.to_a, "#{kind} of #{name} and itself, store"
      end
    end
  end

  def test_mask_takes_the_last_part_with_or_without_a_mask_before
    m = CA_BOOLEAN([1, 0, 1, 0, 0, 1, 0, 1])
    [false, true].each do |had_mask|
      a = CArray.int32(4).seq
      a.mask = 0 if had_mask
      CArray.stack([a, a]).mask = m.reshape(2, 4)
      assert_equal [false, true, false, true], a.is_masked.to_a, "stack, mask before: #{had_mask}"
      a = CArray.int32(4).seq
      a.mask = 0 if had_mask
      CArray.meld(a, a).mask = m
      assert_equal [false, true, false, true], a.is_masked.to_a, "meld, mask before: #{had_mask}"
      a = CArray.int32(3)
      a.mask = 0 if had_mask
      x = CA_INT32([[1, 2, 3], [4, 5, 6]])
      x[0, 1] = UNDEF
      CArray.stack([a, a])[] = x
      assert_equal [4, 5, 6], a.to_a, "store of a masked array, mask before: #{had_mask}"
    end
  end
end

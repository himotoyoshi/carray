# spec_ai/test_multi_parent_unmaskable_part.rb
#
# A value array or a mask array can have no mask.  A part of a stack or a
# meld is an array like any other, which can, so neither is taken as a
# part: building the stack or meld raises.

require "test/unit"
require "carray"

class TestMultiParentUnmaskablePart < Test::Unit::TestCase

  def masked
    a = CArray.int32(2, 3).seq
    a[0, 1] = UNDEF
    a
  end

  def test_value_and_mask_arrays_and_their_views_are_refused
    a = masked
    { "value"           => a.value,
      "view of value"   => a.value[0, nil],
      "cast of value"   => a.value.fake(:uint32),
      "mask"            => a.mask,
      "view of mask"    => a.mask.transpose,
      "mask of a stack" => CArray.stack([a, a]).mask,
      "mask of a meld"  => CArray.meld(a, a).mask,
    }.each do |name, part|
      like = CArray.new(part.data_type, part.shape)
      [ -> { CArray.stack([like, part]) },
        -> { CArray.meld(part, like) },
        -> { CAStack.new([part]) },
        -> { CAMeld.new([part]) },
        -> { CArray.stack([like, like]).append(part) },
      ].each do |build|
        e = assert_raise(ArgumentError, name) { build.call }
        assert_match(/can have no mask and can not be a part/, e.message, name)
      end
    end
  end

  def test_the_mask_of_a_stack_takes_no_append
    s = CArray.stack([masked, masked])
    e = assert_raise(ArgumentError) { s.mask.append(CArray.boolean(2, 3)) }
    assert_match(/mask array/, e.message)
  end

  # The mask of a stack or meld is itself built over the parents' masks.
  def test_the_mask_of_a_stack_or_meld_is_still_built
    a = masked
    assert_equal [[[false, true, false], [false] * 3]] * 2,
                 CArray.stack([a, a]).mask.to_a
    assert_equal [[false, true, false], [false] * 3] * 2,
                 CArray.meld(a, a).mask.to_a
  end

  # A copy of a value array is an array like any other.
  def test_a_copy_of_a_value_array_is_a_part
    a = masked
    s = CArray.stack([a.value.copy, a])
    assert_equal [[0, 1, 2], [3, 4, 5]], s[0, nil, nil].to_a
  end
end

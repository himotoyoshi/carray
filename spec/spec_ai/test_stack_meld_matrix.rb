# CAStack / CAMeld against an entity, over random cases (stack_meld_cases.rb):
# parents of many kinds, chains of views over the stack or meld, and reads
# and writes at the end.  `rake spec_ai_general` and `rake spec_ai_transfer`
# run the same cases with the fast paths switched off.
#
# Below the sweep, the cases it found, written out.

require "test/unit"
require "carray"
require_relative "stack_meld_cases"

class TestStackMeldMatrix < Test::Unit::TestCase

  def test_random_cases_agree_with_an_entity
    fails = (0...10_000).filter_map { |c| StackMeldCases.check(1, c) }
    message = fails.first(10).map { |f| "#{f[0]}\n  view   : #{f[1]}\n  entity : #{f[2]}" }.join("\n")
    assert_equal 0, fails.size, message
  end

  # A reshape folded past a stack onto a parent's root read the root's mask
  # through a value array.
  def test_fold_past_a_stack_keeps_a_value_array_without_mask
    e = CArray.float64(2, 2).seq
    e[0, 0] = UNDEF
    e[1, 1] = UNDEF
    s = CArray.stack([e.value])
    x = s.flip(0).reshape(4)
    assert_equal false, x.has_mask?
    assert_equal false, x.to_a.include?(UNDEF)
    assert_equal 0, x.count_masked
  end

  def test_fold_past_a_stack_keeps_a_mask_array_a_part
    e = CArray.float64(2, 2).seq
    e[0, 0] = UNDEF
    s = CArray.stack([e.mask])
    assert_equal s.mask_array?, s.flip(0).reshape(4).mask_array?
  end

  # The sync of a stack or meld, run by the check of a mask write against a
  # stand-in for a part with no mask yet, wrote into a buffer the stand-in
  # never had (SEGV).
  def test_write_to_a_masked_stack_over_a_stack_of_a_value_array
    a = CArray.int32(1, 2).seq
    a[0, 0] = UNDEF
    i = CArray.stack([CArray.int32(2).seq.value])
    s = CArray.stack([a, i])
    s.map! { |x| x }
    assert_equal [[[UNDEF, 1]], [[0, 1]]], s.to_a
    s.add!(1)
    assert_equal [[[UNDEF, 2]], [[1, 2]]], s.to_a
  end

  def test_write_to_a_masked_meld_over_a_stack_of_a_value_array
    a = CArray.int32(1, 2).seq
    a[0, 0] = UNDEF
    i = CArray.stack([CArray.int32(2).seq.value])
    m = CArray.meld(a, i, axis: 0)
    m.map! { |x| x }
    assert_equal [[UNDEF, 1], [0, 1]], m.to_a
    m.add!(1)
    assert_equal [[UNDEF, 2], [1, 2]], m.to_a
  end

end

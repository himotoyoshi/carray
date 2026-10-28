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

end

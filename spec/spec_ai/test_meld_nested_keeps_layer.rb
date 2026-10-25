# spec_ai/test_meld_nested_keeps_layer.rb
#
# CArray.meld absorbs the parents of a meld along the same axis, so that a
# meld of melds reads as one.  A frozen meld is kept as a piece instead:
# absorbing it would drop the refusal of writes through it.

require "test/unit"
require "carray"

class TestMeldNestedKeepsLayer < Test::Unit::TestCase

  def root
    CArray.int32(2, 3).seq!
  end

  def test_a_frozen_meld_stays_read_only_inside_another
    r = root
    m = CArray.meld(r, r, axis: 0).freeze
    m2 = CArray.meld(m, m, axis: 0)
    assert_equal true, m2.read_only?
    assert_raise(RuntimeError, FrozenError) { m2[0, 0] = 9 }
    assert_equal 0, r[0, 0]
    assert_equal m.to_a + m.to_a, m2.to_a
  end

  # A meld with nothing of its own is still absorbed, and writes go through.
  def test_a_plain_meld_is_absorbed
    r = root
    m = CArray.meld(r, r, axis: 0)
    m2 = CArray.meld(m, r, axis: 0)
    assert_equal 3, m2.parents.size
    m2[0, 0] = 9
    assert_equal 9, r[0, 0]
  end
end

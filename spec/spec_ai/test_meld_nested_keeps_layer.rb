# spec_ai/test_meld_nested_keeps_layer.rb
#
# CArray.meld absorbs the parents of a meld along the same axis, so that a
# meld of melds reads as one.  A read-only meld (frozen or flagged) is kept
# as a piece instead: absorbing it would drop the refusal of writes through
# it.  A read-only stack hands on read-only views of its parents to append.

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

  def test_a_flagged_meld_stays_read_only_inside_another
    r = root
    m = CArray.meld(r, r, axis: 0)
    m.set_read_only_flag
    m2 = CArray.meld(m, m, axis: 0)
    assert_raise(RuntimeError) { m2[0, 0] = 9 }
    assert_equal 0, r[0, 0]
  end

  def test_append_to_a_read_only_stack_keeps_its_parents_read_only
    [->(s) { s.freeze }, ->(s) { s.set_read_only_flag }].each do |lock|
      r = root
      s = CArray.stack([r, r])
      lock.(s)
      t = s.append(CArray.int32(2, 3))
      assert_raise(RuntimeError, FrozenError) { t[0, 0, 0] = 7 }
      assert_equal 0, r[0, 0]
      assert_equal s.to_a, t[0..1, nil, nil].to_a
    end
  end
end

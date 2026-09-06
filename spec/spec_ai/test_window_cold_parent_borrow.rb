# ---------------------------------------------------------------------------
# spec_ai/test_window_cold_parent_borrow.rb
#
# CAWindow / CAShift over an unattached parent
# (= devel/PROPOSAL_LAZY_MARKER_LIFT.md case D).
#
# The transfer slots used to branch on "does the parent have a ptr right
# now", so any parent that happened to be cold -- a plain a[nil, nil], a
# refer, a transpose chain, a lazy marker -- was duplicated in full on
# every transfer (twice on a write: GET the parent, scatter, PUT it back).
# The branch now asks whether the parent has memory to lend, via
# ca_attach_is_alias or ca_resolve_attached_root_via_identity, and borrows
# it when it does.
#
# Borrowing means the window reads and writes the parent's own storage
# rather than a private copy, so the write direction is what this file
# mostly pins: a scatter through a borrowed parent must land in the
# entity, and must land in exactly the cells the entity-rooted path
# would have touched.
# ---------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path('../../../ext', __FILE__)
$LOAD_PATH.unshift File.expand_path('../../../lib', __FILE__)

require 'test/unit'
require 'carray'

class TestWindowColdParentBorrow < Test::Unit::TestCase

  # "block-offset" covers a different rectangle of the entity, so it has no
  # common expected value with the others; the marker family is read-only
  # (pinned separately in test_marker_rooted_window_stays_read_only).
  SKIP_FOR_WRITE = ["block-offset", "marker", "marker-block"].freeze

  # Every parent here is a different view over the same entity.  `entity`
  # is the warm control; the rest are cold (parent.ptr == NULL) and each
  # reaches memory by a different route.
  def parents_of (a)
    {
      "entity"        => a,
      "block"         => a[nil, nil],
      "block-offset"  => a[1..-1, nil],       # base_offset != 0
      "refer"         => a.refer,
      "transpose2"    => a.transpose.transpose,  # only contiguous once composed
      "marker"        => a.lazy,
      "marker-block"  => a[nil, nil].lazy,
    }
  end

  def new_entity
    CArray.float64(5, 6) { |j, i| j * 6 + i }
  end

  def test_parents_are_cold_except_the_control
    a = new_entity
    parents_of(a).each do |name, v|
      if name == "entity"
        assert_equal true, v.attached?, name
      else
        assert_equal false, v.attached?, name
      end
    end
  end

  # === GET ================================================================

  def test_shift_get_matches_entity_path
    a = new_entity
    parents_of(a).each do |name, v|
      want = (name == "block-offset" ? a[1..-1, nil] : a).shift(1, 0)
      assert_equal want.to_a, v.shift(1, 0).to_a, name
    end
  end

  def test_shift_get_with_fill_value
    a = new_entity
    parents_of(a).each do |name, v|
      want = (name == "block-offset" ? a[1..-1, nil] : a).shift(0, -2, fill_value: -1)
      assert_equal want.to_a, v.shift(0, -2, fill_value: -1).to_a, name
    end
  end

  # PERIODIC bounds take the descriptor engine, not the embed path.
  def test_roll_get_matches_entity_path
    a = new_entity
    parents_of(a).each do |name, v|
      want = (name == "block-offset" ? a[1..-1, nil] : a).roll(2, 1)
      assert_equal want.to_a, v.roll(2, 1).to_a, name
    end
  end

  def test_window_get_matches_entity_path
    a = new_entity
    parents_of(a).each do |name, v|
      next if name == "block-offset"
      assert_equal a.window(-1..3, 0..4).to_a, v.window(-1..3, 0..4).to_a, name
    end
  end

  def test_get_over_masked_entity
    a = new_entity
    a[2, 3] = UNDEF
    parents_of(a).each do |name, v|
      next if name == "block-offset"
      want = a.shift(1, 0)
      got  = v.shift(1, 0)
      assert_equal want.mask.to_a, got.mask.to_a, name
      assert_equal want.to_a, got.to_a, name
    end
  end

  # === PUT (the borrowed-parent write path) ===============================

  # A scatter through a cold parent must reach the entity.  Before the
  # borrow this went into a private scratch that was pushed back wholesale;
  # now it writes the entity's storage directly.
  def test_shift_put_reaches_the_entity
    src = CArray.float64(5, 6) { |j, i| 100 + j * 6 + i }

    want = new_entity
    want.shift(1, 0)[] = src

    parents_of(new_entity).each do |name, _|
      a = new_entity
      v = parents_of(a).fetch(name)
      next if SKIP_FOR_WRITE.include?(name)
      v.shift(1, 0)[] = src
      assert_equal want.to_a, a.to_a, name
    end
  end

  def test_roll_put_reaches_the_entity
    src = CArray.float64(5, 6) { |j, i| 100 + j * 6 + i }

    want = new_entity
    want.roll(2, 1)[] = src

    parents_of(new_entity).each do |name, _|
      a = new_entity
      v = parents_of(a).fetch(name)
      next if SKIP_FOR_WRITE.include?(name)
      v.roll(2, 1)[] = src
      assert_equal want.to_a, a.to_a, name
    end
  end

  # An out-of-bounds cell has nowhere to write to; the scatter must drop it
  # rather than wrap or spill into a neighbouring row.
  def test_shift_put_drops_out_of_bounds_cells
    src = CArray.float64(5, 6) { |j, i| 100 + j * 6 + i }

    want = new_entity
    want.shift(-2, 0)[] = src

    parents_of(new_entity).each do |name, _|
      a = new_entity
      v = parents_of(a).fetch(name)
      next if SKIP_FOR_WRITE.include?(name)
      v.shift(-2, 0)[] = src
      assert_equal want.to_a, a.to_a, name
    end
  end

  # A window narrower than the parent must leave the cells outside it alone.
  def test_window_put_leaves_the_rest_of_the_parent_alone
    src = CArray.float64(3, 3) { |j, i| -(j * 3 + i) - 1 }

    want = new_entity
    want.window(1..3, 2..4)[] = src

    parents_of(new_entity).each do |name, _|
      a = new_entity
      v = parents_of(a).fetch(name)
      next if SKIP_FOR_WRITE.include?(name)
      v.window(1..3, 2..4)[] = src
      assert_equal want.to_a, a.to_a, name
    end
  end

  # A marker is read-only, so a write through one must still be refused
  # rather than quietly reaching the borrowed parent.
  def test_marker_rooted_window_stays_read_only
    a = new_entity
    assert_raise(RuntimeError) { a.lazy.shift(1, 0)[] = 0.0 }
    assert_equal new_entity.to_a, a.to_a
  end

  # === fill (scalar broadcast) ============================================

  def test_shift_fill_scalar_reaches_the_entity
    want = new_entity
    want.shift(1, 0)[] = -5.0

    parents_of(new_entity).each do |name, _|
      next if SKIP_FOR_WRITE.include?(name)
      a = new_entity
      v = parents_of(a).fetch(name)
      v.shift(1, 0)[] = -5.0
      assert_equal want.to_a, a.to_a, name
    end
  end

  # === partial region transfer (xfer_stride) ==============================

  # Slicing the window drives the region path rather than a whole-view
  # transfer, which is the second gate case D touches.
  def test_shift_slice_get_matches_entity_path
    a = new_entity
    parents_of(a).each do |name, v|
      next if name == "block-offset"
      assert_equal a.shift(1, 0)[1..3, 2..4].to_a,
                   v.shift(1, 0)[1..3, 2..4].to_a, name
    end
  end

  def test_shift_slice_put_reaches_the_entity
    src = CArray.float64(3, 3) { |j, i| -(j * 3 + i) - 1 }

    want = new_entity
    want.shift(1, 0)[1..3, 2..4] = src

    parents_of(new_entity).each do |name, _|
      next if SKIP_FOR_WRITE.include?(name)
      a = new_entity
      v = parents_of(a).fetch(name)
      v.shift(1, 0)[1..3, 2..4] = src
      assert_equal want.to_a, a.to_a, name
    end
  end
end

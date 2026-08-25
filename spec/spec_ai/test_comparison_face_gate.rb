# frozen_string_literal: true
#
# Comparison-operator Face gate — 2026-07-03.
#
# The element-wise comparison operators (< <= > >=, and <=> which composes
# from > and <) ride the core Face gate (ca_face_reconcile_comparison in
# ext/ca_obj_face.c, called from rb_ca_call_bincmp).  A Face has surface
# data_type CA_FIXLEN, so without the gate these dispatch to the fixlen
# memcmp branch, which orders int64 storage by little-endian byte order --
# wrong for values >= 256 or negative.  The gate descends an ORDERABLE Face
# to numeric storage (fixing the mis-order) and reconciles a Face RHS in a
# different unit via to_comparable (LHS is the reference; lossy raises).
# A fixlen-storage Face (CARecord / string faces) is left on the memcmp
# path.  No per-Face lib override is needed.
#
# See devel/PROPOSAL_FACE_ORDERING_GATE.md (comparison-family extension).

require "test/unit"
require "carray"

class TestComparisonFaceGate < Test::Unit::TestCase

  # little-endian memcmp DISAGREES with numeric order here (see min/max gate)
  def dt(vals, unit: :s)
    a = CArray.int64(vals.size)
    vals.each_with_index { |v, i| a[i] = v }
    a.time(unit: unit)
  end

  # ----- numeric-order descent (memcmp mis-order fixed) ---------------

  def test_lt_uses_numeric_order_not_memcmp
    a = dt([1, 256, -1])
    b = dt([2, 2, 2])
    # numeric: 1<2=T, 256<2=F, -1<2=T
    assert_equal [true, false, true], (a < b).to_a
  end

  def test_gt_and_ge_le_numeric_order
    a = dt([1, 256, -1])
    b = dt([2, 2, 2])
    assert_equal [false, true, false], (a > b).to_a
    assert_equal [true, false, true], (a <= b).to_a
    assert_equal [false, true, false], (a >= b).to_a
  end

  def test_spaceship_composes_from_gated_ops
    a = dt([1, 256, -1])
    b = dt([2, 2, 2])
    # numeric <=>: -1, +1, -1
    assert_equal [-1, 1, -1], (a <=> b).to_a
  end

  # ----- unit reconciliation via to_comparable ------------------------

  def test_diff_unit_reconciles_losslessly
    d_s  = dt([10, 20, 30], unit: :s)
    d_ms = dt([15000, 20000, 25000], unit: :ms)   # 15s, 20s, 25s
    assert_equal [true, false, false], (d_s < d_ms).to_a
  end

  def test_diff_unit_lossy_raises
    d_s  = dt([10], unit: :s)
    d_ms = dt([1500], unit: :ms)   # 1.5s -- not a whole second
    assert_raise(ArgumentError) { d_s < d_ms }
  end

  def test_timedelta_diff_unit_reconciles
    t_s  = CArray.int64(2) { |i| [5, 30][i] }.timedelta(unit: :s)
    t_ms = CArray.int64(2) { |i| [10000, 10000][i] }.timedelta(unit: :ms)  # 10s
    assert_equal [true, false], (t_s < t_ms).to_a
  end

  # ----- plain operand against a non-comparable Face is rejected ------
  # Reference-side reconcile (PROPOSAL_TO_COMPARABLE_RECEIVER_FLIP): the
  # reference Face drives reconciliation via its own to_comparable, so a
  # plain int64 operand it cannot bring into its unit space raises TypeError
  # (not the pre-flip gate-level ArgumentError).  Descend to ca.parent to
  # compare the hidden storage directly.
  def test_plain_operand_rejected
    d = dt([10, 20, 30])
    plain = CArray.int64(3) { |i| [10, 20, 30][i] }
    assert_raise(TypeError) { d < plain }
  end

  # ----- fixlen-storage Face keeps memcmp (record equality) -----------

  def test_record_face_equality_unchanged
    pixel = CArray.struct { uint8 :r }
    r1 = CARecord.new(pixel, 2); r1["r"][0] = 1; r1["r"][1] = 2
    r2 = CARecord.new(pixel, 2); r2["r"][0] = 1; r2["r"][1] = 9
    assert_equal [true, false], r1.eq(r2).to_a
  end

  # ----- masked cells propagate through comparison --------------------

  def test_masked_cell_propagates
    a = CArray.int64(3) { |i| [10, 20, 30][i] }
    a[1] = UNDEF
    da = a.time(unit: :s)
    db = dt([15, 15, 15])
    r = da < db
    assert_equal true, r.has_mask?
    assert_equal [false, true, false], r.is_masked.to_a
  end
end

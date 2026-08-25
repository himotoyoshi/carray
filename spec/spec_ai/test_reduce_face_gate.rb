# frozen_string_literal: true
#
# Reduce-family Face gate — 2026-07-03.
#
# Order-structure reductions (min / max / min_index / max_index) ride the
# same ORDERABLE-storage descent as the sort / search family (ext/mkkernel.rb
# face_gate:).  A Face has surface data_type CA_FIXLEN, so without the gate
# these reductions dispatch to the fixlen memcmp branch, which orders the
# int64 storage by little-endian byte order — wrong for values >= 256 or
# negative.  The gate descends an ORDERABLE Face to its numeric storage
# (fixing the memcmp mis-order) and, for value-returning min / max, re-lifts
# the result back into the Face (scalar via storage_to_scalar, per-axis via
# rb_ca_face_template) — so no per-Face lib override is needed.
#
# See devel/PROPOSAL_FACE_ORDERING_GATE.md (reduce-family extension).

require "test/unit"
require "carray"

class TestReduceFaceGate < Test::Unit::TestCase

  # Values chosen so little-endian memcmp DISAGREES with numeric order:
  #   256 = bytes [0,1,..] sorts below 1 = [1,0,..] by memcmp;
  #   -1  = bytes [0xff,..] sorts above everything by memcmp.
  # Numeric order: -1 < 1 < 256.
  MEMCMP_TRAP = [1, 256, -1].freeze

  def dt_trap
    a = CArray.int64(MEMCMP_TRAP.size)
    MEMCMP_TRAP.each_with_index { |v, i| a[i] = v }
    a.time(unit: :s)
  end

  # ----- Tier 1: position-returning (min_index / max_index) -----------
  # Output is an axis-local index; no re-lift.  The gate only has to route
  # the Face to the numeric path instead of memcmp.

  def test_max_index_on_datetime_uses_numeric_order
    # numeric max is 256 at index 1 (memcmp would wrongly pick -1 at index 2)
    assert_equal 1, dt_trap.max_index
  end

  def test_min_index_on_datetime_uses_numeric_order
    # numeric min is -1 at index 2 (memcmp would wrongly pick 256 at index 1)
    assert_equal 2, dt_trap.min_index
  end

  def test_min_max_addr_on_datetime
    assert_equal 1, dt_trap.max_addr
    assert_equal 2, dt_trap.min_addr
  end

  def test_max_index_per_axis_on_datetime
    m = CArray.int64(2, 3) { |i, j| [[1, 256, -1], [500, 5, 999]][i][j] }
    d = m.time(unit: :s)
    assert_equal [1, 2], d.max_index(axis: 1).to_a
    assert_equal [2, 1], d.min_index(axis: 1).to_a
  end

  def test_max_index_returns_plain_index_not_face
    idx = dt_trap.max_index
    assert_kind_of Integer, idx
  end

  # ----- Tier 2: value-returning (min / max) ---------------------------
  # Descend, then re-lift the storage result back into the Face.

  def test_min_max_full_reduction_returns_scalar_face
    d = dt_trap
    assert_kind_of CATime::Element, d.min
    assert_kind_of CATime::Element, d.max
    assert_equal(-1, d.min.value)   # numeric min, not memcmp
    assert_equal 256, d.max.value
    assert_equal :s, d.min.unit.base
  end

  def test_min_per_axis_returns_face_with_unit
    m = CArray.int64(2, 3) { |i, j| [[1, 256, -1], [500, 5, 999]][i][j] }
    d = m.time(unit: :s)
    r = d.min(axis: 1)
    assert_kind_of CATime, r
    assert_equal :s, r.unit.base
    assert_equal [-1, 5], r.parent.to_a
  end

  def test_min_preserves_mask_on_all_masked_slab
    m = CArray.int64(2, 2) { |i, j| [[10, 20], [30, 40]][i][j] }
    m[0, 0] = UNDEF
    m[0, 1] = UNDEF                 # slab 0 fully masked
    r = m.time(unit: :s).min(axis: 1)
    assert_equal true, r.has_mask?
    assert_equal [true, false], r.is_masked.to_a
    assert_equal 30, r.parent[1]   # slab 1 min unaffected
  end

  def test_min_excludes_masked_cell
    m = CArray.int64(2, 3) { |i, j| [[1, 256, -1], [500, 5, 999]][i][j] }
    m[0, 2] = UNDEF                 # mask the numeric min of slab 0
    r = m.time(unit: :s).min(axis: 1)
    assert_equal [1, 5], r.parent.to_a
  end

  # ----- timedelta rides the same gate --------------------------------

  def test_timedelta_min_max_ride_gate
    a = CArray.int64(3)
    MEMCMP_TRAP.each_with_index { |v, i| a[i] = v }
    d = a.timedelta(unit: :ms)
    assert_kind_of CATimedelta::Element, d.min
    assert_equal(-1, d.min.value)
    assert_equal 256, d.max.value
    assert_equal 2, d.min_index
  end

  # ----- genuine fixlen array is unaffected (still memcmp) -------------

  def test_plain_fixlen_still_uses_memcmp
    fx = CArray.fixlen(2, bytes: 3)
    fx[0] = "abc"
    fx[1] = "abd"
    assert_equal 1, fx.max_index   # "abd" > "abc" lexicographically
    assert_equal 0, fx.min_index
  end

  # ----- non-orderable numeric Face is rejected -----------------------
  # A Face with numeric storage but no ORDERABLE flag must not silently
  # descend (its storage order need not match the surface order).

  class NonOrderableNumFace < CAObject
    def initialize (parent)
      super(CA_INT64, parent.dim, parent: parent, face: true)
    end
  end

  def test_non_orderable_numeric_face_raises
    f = NonOrderableNumFace.new(CArray.int64(4) { |i| [3, 1, 2, 1][i] })
    assert_raise(ArgumentError) { f.max_index }
    assert_raise(ArgumentError) { f.min }
  end
end

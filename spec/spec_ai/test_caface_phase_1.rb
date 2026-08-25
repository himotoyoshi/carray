# PROPOSAL_CAFACE_PHASE_1 F.1 — skeleton smoke tests
#
# Phase 1 段階では具象 Face subclass が存在しないため、live test は
# omit-marked。Phase 1 で pin する真の test は:
#   - flag predicate (= face? が全 instance で false)
#   - CArray::Face module 存在
#   - lift / strip / template helper の compile + load 成功 (= grep + build)
# Phase 2 で具象 Face subclass landed 時に omit を flip。

require 'test/unit'
require 'carray'

class TestCAFacePhase1 < Test::Unit::TestCase

  # ---- F.1.1: flag predicate

  def test_face_returns_false_for_entity
    a = CArray.int32(10)
    assert_equal false, a.face?
  end

  def test_face_returns_false_for_virtual
    a = CArray.int32(4, 5)
    b = a[1..2, nil]
    assert_equal false, b.face?
  end

  def test_face_returns_false_for_scalar
    s = CScalar.int32
    assert_equal false, s.face?
  end

  # ---- F.1.2: CArray::Face module (= 削除済)
  # Phase 1 で起稿された CArray::Face module + WRAP_METHODS / STRIP_METHODS
  # は C 層 macro deploy (= F.2.13 以降) + copy_state / storage_to_scalar
  # convention (= F.3.x) で代替され dead weight 化、本 turn で削除。
  # face? predicate と他 Face mechanism は無関係に動作する。

  # ---- F.1.4 / F.1.5 / F.1.6: live test は Phase 2 で flip

  # ---- F.1.4 / F.1.5 / F.1.6 — Phase 2 で flip 済 (= CATime = 最初の live consumer)

  def test_face_template_duplicates_subclass_struct
    raw = CArray.int64(5) {|i| i * 10}
    dt = CATime.wrap(raw, unit: :ns)
    assert_equal :ns, dt.unit.base
    # template が tail 含めて複製: dt[range] (= lift 経由) で unit carry
    slice = dt[1..3]
    assert_equal CATime, slice.class
    assert_equal :ns, slice.unit.base
  end

  def test_face_lift_auto_activates_on_aref
    raw = CArray.int64(10) {|i| i * 100}
    dt = CATime.wrap(raw, unit: :s)
    sliced = dt[2..5]
    assert_equal CATime, sliced.class, "lift hook should auto-wrap"
    assert_equal :s, sliced.unit.base
    assert_equal 4, sliced.elements
  end

  def test_aref_lift_pin
    raw = CArray.int64(8) {|i| i * 1_000_000_000}
    dt = CATime.wrap(raw, unit: :ns)
    # lift hook 経由で .parent が underlying view (CABlock 等) を指す
    sliced = dt[3..6]
    refute_nil sliced.parent, "lift hook should set Ruby-level parent for GC"
  end

  # ---- L0 invariants (MEMO §15.2、Phase 2 で flip)
  # 注: 完全な L0 (kernel_iterator strip / lazy marker / binop tree) は F.2.6 / F.2.7
  # で wire 後に testable、ここでは flag predicate level の最小 invariant

  def test_l0_face_flag_set_on_face
    raw = CArray.int64(5)
    dt = CATime.wrap(raw, unit: :ns)
    assert_equal true, dt.face?
  end

  def test_l0_face_flag_not_set_on_parent
    raw = CArray.int64(5)
    refute_equal true, raw.face?, "parent (entity) must not carry face flag"
  end

  def test_l0_face_subclass_is_a_carray
    raw = CArray.int64(5)
    dt = CATime.wrap(raw, unit: :ns)
    assert_kind_of CArray, dt, "Face must be a CArray subclass (= 外から普通の view)"
    assert_kind_of CAView, dt, "Face is under CAView hierarchy (Q7 (β))"
  end
end

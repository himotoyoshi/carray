# PROPOSAL_LAZY_ELEMENTWISE_VIEW Phase 2 (P.2.1) — CABinOp smoke.
#
# Scope (= prep doc rev3 P.2.1):
#   - ADD only, f64 only, vv only.
#   - vector+vector, scalar-on-right, scalar-on-left (coerce sv entry).
#   - readonly raise, mask propagation, scratch=1-per-node, materialise
#     counter pattern (§3.4 taxonomy).
#   - chain (a.lazy+b)+c and monop+binop interop.
#
# P.2.2 will expand parity to 13 op × ALL_NUMERIC with mid-data_type cast
# pin; P.2.3 wires scalar variants; P.2.4 adds general broadcast.

$LOAD_PATH.unshift File.expand_path("../../ext", __dir__)
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "carray"
require "test/unit"

class TestLazyBinopP21 < Test::Unit::TestCase

  # ------------------------------------------------------------- basic --

  def test_cabinop_class_exists
    assert defined?(CABinOp), "CABinOp class should be defined"
    assert_operator CABinOp, :<, CAView
  end

  def test_op_add_constant_wired
    assert_equal 0, CABinOp::OP_ADD
  end

  def test_vector_plus_vector_byte_parity
    a = CArray.float64(64).seq
    b = CArray.float64(64).seq + 10
    v = a.lazy + b
    assert_kind_of CABinOp, v
    assert_equal((a + b).dump_binary, v.to_ca.dump_binary)
  end

  def test_2d_vector_plus_vector_byte_parity
    a = CArray.float64(8, 8).seq
    b = CArray.float64(8, 8).seq + 100
    v = a.lazy + b
    assert_equal((a + b).dump_binary, v.to_ca.dump_binary)
  end

  # --------------------------------------------------------- scalar --

  def test_array_plus_scalar_byte_parity
    a = CArray.float64(64).seq
    v = a.lazy + 100.0
    assert_kind_of CABinOp, v
    assert_equal((a + 100.0).dump_binary, v.to_ca.dump_binary)
  end

  def test_scalar_plus_array_via_coerce_sv_entry
    # rev3 §3.7 / load-bearing #4: coerce keeps lazy, returns
    # [CScalar(2), self], then `+` re-dispatches with lazy receiver.
    a = CArray.float64(64).seq
    v = 100.0 + a.lazy
    assert_kind_of CABinOp, v
    assert_equal((a + 100.0).dump_binary, v.to_ca.dump_binary)
  end

  # --------------------------------------------------------- readonly --

  def test_setitem_raises
    a = CArray.float64(5).seq
    b = CArray.float64(5).seq
    v = a.lazy + b
    assert_raise(RuntimeError) { v[0] = 999.0 }
  end

  def test_fill_data_raises
    a = CArray.float64(5).seq
    b = CArray.float64(5).seq
    v = a.lazy + b
    assert_raise(RuntimeError) { v.fill(999.0) }
  end

  # --------------------------------------------------------- mask --

  def test_mask_propagation_from_left
    a = CArray.float64(8).seq
    a[2] = UNDEF
    b = CArray.float64(8).seq
    v = a.lazy + b
    out = v.to_ca
    assert_true out.has_mask?
    assert_kind_of UndefClass, out[2]
  end

  def test_mask_propagation_from_right
    a = CArray.float64(8).seq
    b = CArray.float64(8).seq
    b[3] = UNDEF
    v = a.lazy + b
    out = v.to_ca
    assert_true out.has_mask?
    assert_kind_of UndefClass, out[3]
  end

  def test_mask_propagation_both
    a = CArray.float64(8).seq;  a[2] = UNDEF
    b = CArray.float64(8).seq;  b[3] = UNDEF
    v = a.lazy + b
    out = v.to_ca
    assert_kind_of UndefClass, out[2]
    assert_kind_of UndefClass, out[3]
  end

  # ---------------------------------------- scratch / materialise --

  def test_one_binop_uses_exactly_one_scratch
    a = CArray.float64(64).seq
    b = CArray.float64(64).seq
    CABinOp.__reset_scratch_counter__
    CABinOp.__reset_materialise_counter__
    _ = (a.lazy + b).to_ca
    # 1 CABinOp node ⇒ exactly 1 right-side scratch acquire and 1
    # xfer_stride invocation on the root.
    assert_equal 1, CABinOp.__scratch_count__
    assert_equal 1, CABinOp.__materialise_count__
  end

  def test_two_binop_chain_uses_two_scratches_strahler_bound
    # `(a.lazy + b) + c` — left-leaning chain, Strahler-style peak
    # along the in-place output corresponds to one scratch per node.
    # We pin "= number of CABinOp nodes" rather than a fixed 2 so the
    # property test in P.2.5 can compute the actual bound per tree.
    a = CArray.float64(64).seq
    b = CArray.float64(64).seq
    c = CArray.float64(64).seq
    CABinOp.__reset_scratch_counter__
    CABinOp.__reset_materialise_counter__
    _ = ((a.lazy + b) + c).to_ca
    assert_equal 2, CABinOp.__scratch_count__
    assert_equal 2, CABinOp.__materialise_count__
  end

  def test_chain_byte_parity
    a = CArray.float64(32).seq
    b = CArray.float64(32).seq + 5
    c = CArray.float64(32).seq + 17
    v = ((a.lazy + b) + c)
    assert_equal((a + b + c).dump_binary, v.to_ca.dump_binary)
  end

  # ------------------------------------------- monop ↔ binop interop --

  def test_monop_in_binop_left
    a = CArray.float64(16).seq + 1.0  # avoid sqrt(0) noise
    b = CArray.float64(16).seq
    v = a.lazy.sqrt + b
    assert_kind_of CABinOp, v
    assert_equal((a.sqrt + b).dump_binary, v.to_ca.dump_binary)
  end

  # --------------------------------------------- taxonomy (§3.4) --

  def test_each_materialises
    a = CArray.float64(8).seq
    b = CArray.float64(8).seq
    v = a.lazy + b
    assert_equal (a + b).to_a, v.each.to_a
  end

  def test_to_a_materialises
    a = CArray.float64(8).seq
    b = CArray.float64(8).seq
    v = a.lazy + b
    assert_equal (a + b).to_a, v.to_a
  end

  # ----------------------------------------------- MV reject --

  def test_to_memory_view_raises
    # Ruby-level taxonomy hook in lib/carray/lazy.rb#to_memory_view.
    a = CArray.float64(8).seq
    b = CArray.float64(8).seq
    v = a.lazy + b
    e = assert_raise(TypeError) { v.to_memory_view }
    assert_match(/to_ca/, e.message)
  end

  def test_to_ca_then_mv_wrappable
    # After materialise the entity is MV-eligible (= wrap_memory_view
    # succeeds without raising).  This pins that the lazy reject is at
    # the lazy layer only and does NOT taint the materialised entity.
    a = CArray.float64(8).seq
    b = CArray.float64(8).seq
    materialised = (a.lazy + b).to_ca
    assert_true CArray.memory_view_available?(materialised)
    assert_not_nil CArray.wrap_memory_view(materialised)
  end

  # ------------------------------------ lazy predicate covers BINOP --

  def test_is_lazy_view_predicate_covers_binop
    # rev3 §3.5b / medium #7: ca_is_lazy_view must include CABinOp so
    # that chained ops route into the lazy builder.
    a = CArray.float64(8).seq
    b = CArray.float64(8).seq
    v = a.lazy + b
    assert_true v.__lazy_view__?
  end
end

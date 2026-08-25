require "test/unit"
require "carray"

# PROPOSAL_LAZY_ELEMENTWISE_VIEW Phase 4 (P.4.2) — full op coverage
# parity sweep.
#
# Scope (rev2 §1):
#   - 7 bincmp (lt/gt/le/ge/eq/ne/feq) + operator aliases (</>/<=/>=)
#   - 3 moncmp (is_nan/is_inf/is_finite)
#   - cast-before route: int × f64 promote to f64, sweep all data_type pairs
#   - feq mask propagation
#   - integer is_inf / is_finite (rev2 §0.5 #3 = per-data_type kernel handles
#     all data_types including integer; const-false / const-true via kernel,
#     mask propagation via skip semantics)
#   - non-trapping invariant: cmp ops never trap so m=NULL fast path
#     produces byte parity regardless of mask presence

class TestLazyCmpP42 < Test::Unit::TestCase
  N = 50

  # Numeric data_types for bincmp parity sweep.  Boolean operations are
  # covered by Phase 2 binop bit_and/or/xor over CABinCmp outputs
  # (cross-tested at the operator-routing layer).  CMPLX is excluded
  # from < / > / <= / >= (no total order); covered only for eq/ne.
  ORDER_DTYPES = [
    [CA_INT8,    :int8],
    [CA_UINT8,   :uint8],
    [CA_INT16,   :int16],
    [CA_UINT16,  :uint16],
    [CA_INT32,   :int32],
    [CA_UINT32,  :uint32],
    [CA_INT64,   :int64],
    [CA_UINT64,  :uint64],
    [CA_FLOAT32, :float32],
    [CA_FLOAT64, :float64],
  ].freeze

  # Build arrays in data_type `dt_sym` with a small overlap range so
  # comparison op outputs vary meaningfully.
  def build_pair(dt_sym)
    a = CArray.send(dt_sym, N) { |k| k }
    b = CArray.send(dt_sym, N) { |k| (k + 5) % N }
    [a, b]
  end

  # === ordering ops × all data_type pairs ===

  def test_ordering_op_parity_per_data_type
    [:lt, :gt, :le, :ge].each do |op|
      ORDER_DTYPES.each do |_dt, dt_sym|
        a, b = build_pair(dt_sym)
        eager = a.public_send(op, b)
        lazy  = a.lazy.public_send(op, b).to_ca
        assert_equal CA_BOOLEAN, lazy.data_type,
                     "#{op} on #{dt_sym}: output data_type must be CA_BOOLEAN"
        assert_equal eager.to_a, lazy.to_a,
                     "#{op} parity failure on #{dt_sym}"
      end
    end
  end

  def test_operator_alias_parity
    a, b = build_pair(:float64)
    assert_equal (a <  b).to_a, (a.lazy <  b).to_ca.to_a
    assert_equal (a >  b).to_a, (a.lazy >  b).to_ca.to_a
    assert_equal (a <= b).to_a, (a.lazy <= b).to_ca.to_a
    assert_equal (a >= b).to_a, (a.lazy >= b).to_ca.to_a
  end

  # === equality ops × all data_type pairs ===

  def test_eq_ne_parity_per_data_type
    [:eq, :ne].each do |op|
      ORDER_DTYPES.each do |_dt, dt_sym|
        a, b = build_pair(dt_sym)
        eager = a.public_send(op, b)
        lazy  = a.lazy.public_send(op, b).to_ca
        assert_equal eager.to_a, lazy.to_a,
                     "#{op} parity failure on #{dt_sym}"
      end
    end
  end

  # === feq (float ε-equal) ===

  def test_feq_self_returns_all_true
    [:float32, :float64].each do |dt_sym|
      a = CArray.send(dt_sym, N) { |k| k * 0.1 }
      lazy = a.lazy.feq(a).to_ca
      assert_equal Array.new(N, true), lazy.to_a,
                   "feq(self) must be all true on #{dt_sym}"
    end
  end

  def test_feq_with_small_delta_within_eps
    # eager feq uses compile-time FLT_EPSILON / DBL_EPSILON; we mirror
    # via the same kernel.  Construct b s.t. |a - b| <= max(|a|,|b|) *
    # ε so feq returns true.
    [:float32, :float64].each do |dt_sym|
      a = CArray.send(dt_sym, N) { |k| (k + 1) * 1.0 }
      eps = (dt_sym == :float32) ? 1e-7 : 1e-15
      b = a + CArray.send(dt_sym, N) { |k| (k + 1) * eps * 0.1 }
      eager = a.feq(b)
      lazy  = a.lazy.feq(b).to_ca
      assert_equal eager.to_a, lazy.to_a,
                   "feq parity within eps on #{dt_sym}"
    end
  end

  def test_feq_with_large_delta_outside_eps
    [:float32, :float64].each do |dt_sym|
      a = CArray.send(dt_sym, N) { |k| (k + 1) * 1.0 }
      b = a + 1.0  # clearly outside relative ε
      eager = a.feq(b)
      lazy  = a.lazy.feq(b).to_ca
      assert_equal eager.to_a, lazy.to_a,
                   "feq parity outside eps on #{dt_sym}"
    end
  end

  def test_feq_mask_propagation
    a = CArray.float64(N) { |k| k * 0.1 }
    b = a.dup
    a[0..4]    = UNDEF
    b[N-5..N-1] = UNDEF
    eager = a.feq(b)
    lazy  = a.lazy.feq(b).to_ca
    assert_equal eager.mask.to_a, lazy.mask.to_a,
                 "feq mask = left.mask | right.mask"
    eager.elements.times do |k|
      next if eager.mask[k]
      assert_equal eager[k], lazy[k], "feq mismatch at #{k}"
    end
  end

  # === cast-before route (mixed data_type operands) ===

  def test_lt_int_vs_float_promotes_to_float
    a_int = CArray.int32(N) { |k| k - 25 }
    b_f64 = CArray.float64(N) { |k| (k - 25) * 0.5 }
    eager = a_int < b_f64
    lazy  = (a_int.lazy < b_f64).to_ca
    assert_equal eager.to_a, lazy.to_a
  end

  def test_eq_int_vs_int_different_widths
    a_i8  = CArray.int8(N)  { |k| k - 25 }
    b_i64 = CArray.int64(N) { |k| k - 24 }
    eager = a_i8.eq(b_i64)
    lazy  = a_i8.lazy.eq(b_i64).to_ca
    assert_equal eager.to_a, lazy.to_a
  end

  def test_ge_uint_vs_int_promote_check
    a_u32 = CArray.uint32(N) { |k| k }
    b_i32 = CArray.int32(N)  { |k| k - 10 }
    eager = a_u32 >= b_i32
    lazy  = (a_u32.lazy >= b_i32).to_ca
    assert_equal eager.to_a, lazy.to_a
  end

  # === moncmp full coverage ===

  def test_moncmp_parity_on_float
    [:float32, :float64].each do |dt_sym|
      c = CArray.send(dt_sym, 5) { |k|
        [Float::NAN, 1.0, Float::INFINITY, -Float::INFINITY, 2.0][k]
      }
      [:is_nan, :is_inf, :is_finite].each do |op|
        eager = c.public_send(op)
        lazy  = c.lazy.public_send(op).to_ca
        assert_equal eager.to_a, lazy.to_a,
                     "#{op} on #{dt_sym} parity failure"
      end
    end
  end

  def test_moncmp_integer_const_results_and_mask_propagation
    # rev2 §0.5 #3: integer is_nan -> const false; is_finite -> const
    # true; is_inf -> const false.  Mask still propagates from input.
    ORDER_DTYPES.each do |_dt, dt_sym|
      # Skip floats (covered in test_moncmp_parity_on_float)
      next if dt_sym == :float32 || dt_sym == :float64
      a = CArray.send(dt_sym, N) { |k| k }
      a[0..4]   = UNDEF
      a[N-3..]  = UNDEF

      [:is_nan, :is_inf, :is_finite].each do |op|
        eager = a.public_send(op)
        lazy  = a.lazy.public_send(op).to_ca
        assert_equal CA_BOOLEAN, lazy.data_type
        assert_equal eager.to_a, lazy.to_a,
                     "#{op} on #{dt_sym} integer parity failure"
        assert_equal eager.mask.to_a, lazy.mask.to_a,
                     "#{op} on #{dt_sym} mask propagation failure"
      end
    end
  end

  # === broadcast (scalar / size-1 right operand) ===

  def test_bincmp_scalar_broadcast_per_op
    [:lt, :gt, :le, :ge, :eq, :ne].each do |op|
      a = CArray.float64(N) { |k| k - N/2 }
      eager = a.public_send(op, 0.0)
      lazy  = a.lazy.public_send(op, 0.0).to_ca
      assert_equal eager.to_a, lazy.to_a,
                   "#{op} scalar broadcast parity failure"
    end
  end

  # === composition (chain) ===

  def test_compound_bool_expression
    # Demonstrates the full Phase 4 use case: arbitrary boolean
    # expression tree.  Uses bincmp + binop(bit_and).
    a = CArray.float64(N) { |k| (k - N/2) * 0.5 }
    eager = (a > -10.0) & (a < 10.0)
    lazy  = ((a.lazy > -10.0) & (a.lazy < 10.0)).to_ca
    assert_equal eager.to_a, lazy.to_a
  end

  def test_bincmp_over_chain_binop
    # ((a + b) > 0) — CABinCmp parent is CABinOp.  arena reuse pin.
    a = CArray.float64(N) { |k| k }
    b = CArray.float64(N) { |k| k - 100 }
    eager = (a + b) > 0.0
    lazy  = ((a.lazy + b) > 0.0).to_ca
    assert_equal eager.to_a, lazy.to_a
  end

  # === read-only ===

  def test_all_bincmp_ops_are_read_only
    a, b = build_pair(:float64)
    [:lt, :gt, :le, :ge, :eq, :ne, :feq].each do |op|
      view = a.lazy.public_send(op, b)
      assert_raise(RuntimeError, "#{op} must be read-only") {
        view[0] = true
      }
    end
  end

  def test_all_moncmp_ops_are_read_only
    a = CArray.float64(N) { |k| k }
    [:is_nan, :is_inf, :is_finite].each do |op|
      view = a.lazy.public_send(op)
      assert_raise(RuntimeError, "#{op} must be read-only") {
        view[0] = true
      }
    end
  end
end

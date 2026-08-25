# PROPOSAL_LAZY_ELEMENTWISE_VIEW Phase 2 (P.2.2) — 13-op parity sweep.
#
# Scope (= prep doc rev3 P.2.2):
#   - 13 binop wired in dispatch (= Q1 (b) verdict)
#   - byte parity on ALL_NUMERIC for same-data_type inputs (= the
#     cast-before route reduces to a single 1-D lookup once both
#     operands are at the common data_type)
#   - mixed-data_type cast-before pin (insert CAMonOp(:cast_<common>) on
#     the lower-precision operand)
#   - trapping op (integer DIV / MOD / QUO) with masked-zero divisor
#     must NOT SIGFPE — slab mask is built from operand-side masks and
#     passed to the kernel which skips masked cells
#   - mid-chain cast (preserve op before widening op) regression

$LOAD_PATH.unshift File.expand_path("../../ext", __dir__)
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "carray"
require "test/unit"

class TestLazyBinopP22 < Test::Unit::TestCase

  # ------------------------------------------------------------ scope --

  THIRTEEN_OPS = %i[+ - * / ** & | ^ << >> % rcp_mul].freeze

  ARITHMETIC_OPS = %i[+ - * / ** % rcp_mul].freeze
  BITWISE_OPS    = %i[& | ^ << >>].freeze

  FLOAT_DTYPES   = %i[float32 float64].freeze
  INT_DTYPES     = %i[int8 uint8 int16 uint16 int32 uint32 int64 uint64].freeze

  # ----------------------------------------------------- 13-op wired --

  def test_all_thirteen_ops_have_op_id
    THIRTEEN_OPS.each do |op|
      assert CArray::LAZY_BINOP_OP_IDS.key?(op),
             "expected #{op.inspect} in LAZY_BINOP_OP_IDS"
    end
    # Originally 13 (P.2.2); M.2 + M.3 added 6 PyTorch-aligned float-only
    # binops (copysign / logaddexp / nextafter / fmod / atan2 / hypot)
    # bringing the total to 19.  3.0 surface trim removed :quo (galapagos
    # thin wrapper, see MEMO_GALAPAGOS_ESCAPE.md 2026-06-23) bringing the
    # total to 18.  pmax / pmin (NaN-skip) and maximum / minimum
    # (NaN-propagate) added via the M.2 pattern bring the total to 22.
    # and / or / xor (bool word forms) + reminder (IEEE 754 remainder,
    # distinct from mod) bring the total to 26.
    assert_equal 26, CArray::LAZY_BINOP_OP_IDS.size
  end

  # --------------------------------------- arithmetic same-data_type f64 --

  def test_arithmetic_same_f64_byte_parity
    a = CArray.float64(64).seq + 1.0
    b = CArray.float64(64).seq + 2.0
    ARITHMETIC_OPS.each do |op|
      v = a.lazy.send(op, b)
      e = a.send(op, b)
      assert_equal e.dump_binary, v.to_ca.dump_binary,
                   "f64 #{op.inspect} parity"
    end
  end

  def test_arithmetic_same_f32_byte_parity
    a = CArray.float32(64).seq + 1.0
    b = CArray.float32(64).seq + 2.0
    ARITHMETIC_OPS.each do |op|
      v = a.lazy.send(op, b)
      e = a.send(op, b)
      assert_equal e.dump_binary, v.to_ca.dump_binary,
                   "f32 #{op.inspect} parity"
    end
  end

  # ------------------------------- bitwise / shift on integer data_types --

  def test_bitwise_int_byte_parity
    # & | ^ on integer data_types (bit count unconstrained).
    [:int8, :uint8, :int16, :uint16, :int32, :uint32, :int64, :uint64].each do |dt|
      a = CArray.send(dt, 64).seq + 1
      b = CArray.send(dt, 64).seq + 1
      [:&, :|, :^].each do |op|
        v = a.lazy.send(op, b)
        e = a.send(op, b)
        assert_equal e.to_a, v.to_ca.to_a, "#{dt} #{op.inspect} parity"
      end
    end
  end

  def test_shift_int_byte_parity
    # << >> require a shift count strictly less than the type's bit
    # width (C's `<<` / `>>` are UB otherwise — both eager and lazy
    # kernels compute the same UB but the underlying CPU may produce
    # different results across passes).  Cap the shift count at 3
    # universally so we exercise the kernel on valid input.
    [:int8, :uint8, :int16, :uint16, :int32, :uint32, :int64, :uint64].each do |dt|
      a = CArray.send(dt, 64).seq + 1
      b = CArray.send(dt, 64)
      64.times { |i| b[i] = i % 4 }
      [:<<, :>>].each do |op|
        v = a.lazy.send(op, b)
        e = a.send(op, b)
        assert_equal e.to_a, v.to_ca.to_a, "#{dt} #{op.inspect} parity"
      end
    end
  end

  # ---------------------------------------------------- mixed-data_type --

  def test_mixed_int_float_promotes_to_common
    ai = CArray.int32(64).seq
    af = CArray.float64(64).seq + 0.5
    v = ai.lazy + af
    assert_equal :float64, v.data_type_name.to_sym
    assert_equal((ai + af).dump_binary, v.to_ca.dump_binary)
  end

  def test_mixed_int_float_either_side_cast_inserts
    ai = CArray.int32(64).seq
    af = CArray.float64(64).seq + 0.5
    # left = int, right = float
    v1 = ai.lazy + af
    # left = float, right = int
    v2 = af.lazy + ai
    assert_equal((ai + af).dump_binary, v1.to_ca.dump_binary)
    assert_equal((af + ai).dump_binary, v2.to_ca.dump_binary)
  end

  def test_mixed_int32_int64
    ai = CArray.int32(64).seq + 1
    bi = CArray.int64(64).seq + 1
    v = ai.lazy + bi
    assert_equal :int64, v.data_type_name.to_sym
    assert_equal((ai + bi).dump_binary, v.to_ca.dump_binary)
  end

  # ----------------------------- scalar promotes per array data_type --

  def test_scalar_on_right_promotes_to_array_data_type
    af = CArray.float32(64).seq
    v = af.lazy + 2.5
    assert_equal :float32, v.data_type_name.to_sym
    assert_equal((af + 2.5).dump_binary, v.to_ca.dump_binary)
  end

  def test_integer_scalar_on_right_preserves_int_data_type
    ai = CArray.int32(64).seq
    v = ai.lazy + 7
    assert_equal :int32, v.data_type_name.to_sym
    assert_equal((ai + 7).dump_binary, v.to_ca.dump_binary)
  end

  # ----------------------------------------- trapping op: no SIGFPE --

  def test_int_div_masked_zero_divisor_no_sigfpe
    # rev3 load-bearing #2: this test MUST exist or a masked-zero
    # divisor will crash the process at first integer division on a
    # masked CArray.  Eager skips the cell via its kernel mask
    # branch; the lazy path must do the same by building a slab mask
    # from operand-side masks before calling the kernel.
    a = CArray.int32(8).seq + 10
    b = CArray.int32(8).seq          # contains a zero at index 0
    b[0] = UNDEF                      # mask the zero (eager skips)
    out = (a.lazy / b).to_ca          # MUST NOT crash
    # Value parity (eager-compatible, mask-aware)
    expected = a / b
    assert_equal expected.to_a, out.to_a
    # Masked cell remains UNDEF
    assert_kind_of UndefClass, out[0]
  end

  def test_int_mod_masked_zero_divisor_no_sigfpe
    a = CArray.int32(8).seq + 10
    b = CArray.int32(8).seq
    b[0] = UNDEF
    out = (a.lazy % b).to_ca
    expected = a % b
    assert_equal expected.to_a, out.to_a
    assert_kind_of UndefClass, out[0]
  end

  def test_int_div_unmasked_path_byte_parity
    # Sanity: when neither operand is masked, the kernel sees m=NULL
    # and runs the SIMD fast path; result must byte-match eager.
    a = CArray.int32(64).seq + 100
    b = CArray.int32(64).seq + 1
    v = a.lazy / b
    assert_equal((a / b).dump_binary, v.to_ca.dump_binary)
  end

  # ----------------------------- mid-chain cast: monop ∘ binop --

  def test_mid_chain_cast_through_binop
    # Phase 1 finding #1: a preserve op (e.g. :neg) followed by a
    # widening monop on an integer parent puts a CAMonOp(:cast)
    # node mid-chain.  Phase 2 adds binop; the same situation can
    # arise on either operand and must still produce correct
    # results.
    ai = CArray.int16(32).seq + 1
    af = CArray.float64(32).seq + 0.25
    v = ai.lazy.neg.sqrt + af
    e = ai.neg.sqrt + af
    assert_equal e.dump_binary, v.to_ca.dump_binary
  end

  # --------------------------------------------- chain binop * 3 --

  def test_three_binop_chain_byte_parity
    a = CArray.float64(64).seq + 1.0
    b = CArray.float64(64).seq + 2.0
    c = CArray.float64(64).seq + 3.0
    d = CArray.float64(64).seq + 4.0
    v = ((a.lazy + b) * c) - d
    e = ((a + b) * c) - d
    assert_equal e.dump_binary, v.to_ca.dump_binary
  end

  def test_three_binop_chain_scratch_count
    a = CArray.float64(64).seq + 1.0
    b = CArray.float64(64).seq + 2.0
    c = CArray.float64(64).seq + 3.0
    d = CArray.float64(64).seq + 4.0
    CABinOp.__reset_scratch_counter__
    CABinOp.__reset_materialise_counter__
    _ = (((a.lazy + b) * c) - d).to_ca
    # 3 CABinOp nodes in a left-leaning chain ⇒ 3 right-side scratch
    # acquires (= one per node, depth-independent within a chain).
    assert_equal 3, CABinOp.__scratch_count__
    assert_equal 3, CABinOp.__materialise_count__
  end

end

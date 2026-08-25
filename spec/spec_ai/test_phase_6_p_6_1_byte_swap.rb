require "test/unit"
require "carray"

# Phase 6 P.6.1 — byte_swap op family for CAMonOp.
#
# Q3 (Z) lock: 単一 op_id (CA_MONOP_BYTE_SWAP = 35) + per-data_type kernel
# table (ext/ca_op_byte_swap.c).  Q4 (Q): hand-written shim.
#
# Acceptance: CAMonOp.__build__(arr, 35) で生成した view が legacy
# CAByteSwap (arr.swap_bytes) と全 data_type で byte parity.  CMPLX64/CMPLX128
# は half-independent swap (= real/imag halves を独立に swap).
#
# 注: Ruby surface (arr.swap_bytes) の CAMonOp(byte_swap) migration は
# P.6.3 で実施する.  本 test は kernel 単体の verify.

class TestPhase6P61ByteSwap < Test::Unit::TestCase

  BYTE_SWAP_OP_ID = 35   # CA_MONOP_BYTE_SWAP

  # ----- byte parity vs legacy CAByteSwap (= a.swap_bytes) -----

  def test_int16_byte_parity
    a = CArray.int16(4).seq!(1)
    v = CAMonOp.__build__(a, BYTE_SWAP_OP_ID)
    assert_equal a.swap_bytes.to_a, v.to_a
  end

  def test_int32_byte_parity
    a = CArray.int32(8) { |i| 0x01020304 + i }
    v = CAMonOp.__build__(a, BYTE_SWAP_OP_ID)
    assert_equal a.swap_bytes.to_a, v.to_a
  end

  def test_int64_byte_parity
    a = CArray.int64(4).seq!(1)
    v = CAMonOp.__build__(a, BYTE_SWAP_OP_ID)
    assert_equal a.swap_bytes.to_a, v.to_a
  end

  def test_uint32_byte_parity
    a = CArray.uint32(4) { |i| 0xCAFEBABE + i }
    v = CAMonOp.__build__(a, BYTE_SWAP_OP_ID)
    assert_equal a.swap_bytes.to_a, v.to_a
  end

  def test_float32_byte_parity
    a = CArray.float32(4).seq!(1.5)
    v = CAMonOp.__build__(a, BYTE_SWAP_OP_ID)
    assert_equal a.swap_bytes.to_a, v.to_a
  end

  def test_float64_byte_parity
    a = CArray.float64(8).seq!(1.5)
    v = CAMonOp.__build__(a, BYTE_SWAP_OP_ID)
    assert_equal a.swap_bytes.to_a, v.to_a
  end

  # ----- CMPLX half-independent swap -----

  def test_cmplx64_half_independent_swap
    a = CArray.cmplx64(3) { |i| Complex(i.to_f, -i.to_f) }
    v = CAMonOp.__build__(a, BYTE_SWAP_OP_ID)
    # Real / imag halves each 4-byte swapped independently.
    assert_equal a.swap_bytes.to_a, v.to_a
  end

  def test_cmplx128_half_independent_swap
    a = CArray.cmplx128(3) { |i| Complex(i.to_f, -i.to_f) }
    v = CAMonOp.__build__(a, BYTE_SWAP_OP_ID)
    # Real / imag halves each 8-byte swapped independently.
    assert_equal a.swap_bytes.to_a, v.to_a
  end

  # ----- 1-byte data_types (identity) -----

  def test_int8_byte_parity_identity
    a = CArray.int8(4).seq!(1)
    v = CAMonOp.__build__(a, BYTE_SWAP_OP_ID)
    assert_equal a.to_a, v.to_a   # 1 byte = identity swap
  end

  def test_uint8_byte_parity_identity
    a = CArray.uint8(4) { |i| 0x10 + i }
    v = CAMonOp.__build__(a, BYTE_SWAP_OP_ID)
    assert_equal a.to_a, v.to_a
  end

  def test_boolean_byte_parity_identity
    a = CArray.boolean(4) { |i| i.odd? }
    v = CAMonOp.__build__(a, BYTE_SWAP_OP_ID)
    assert_equal a.to_a, v.to_a
  end

  # ----- view-level properties -----

  def test_view_class_is_camonop
    a = CArray.int32(4).seq!(1)
    v = CAMonOp.__build__(a, BYTE_SWAP_OP_ID)
    assert_kind_of CAMonOp, v
  end

  def test_view_preserves_data_type_and_bytes
    a = CArray.int32(4).seq!(1)
    v = CAMonOp.__build__(a, BYTE_SWAP_OP_ID)
    assert_equal a.data_type, v.data_type
    assert_equal a.bytes, v.bytes
  end

  def test_view_is_writable_after_p63
    # P.6.3: byte_swap is now a writable-view op (= CAFake-style
    # writable lifecycle, involution sync).  CAMonOp(byte_swap) returns
    # a writable view; writes propagate through byte_swap (re-swap on
    # the way back to parent).
    a = CArray.int32(4).seq!(1)
    v = CAMonOp.__build__(a, BYTE_SWAP_OP_ID)
    assert_equal false, v.read_only?
  end

  def test_p63_writable_byte_swap_write_path
    # P.6.3: v[i] = N → byte_swap(N) → parent[i].  Read v[i] re-swaps
    # parent → N (involution).  Use uint32 to avoid signed wraparound in
    # the assertion values.
    a = CArray.uint32(4) { |i| 0x01020304 + i }
    v = CAMonOp.__build__(a, BYTE_SWAP_OP_ID)
    v[0] = 0xAABBCCDD
    assert_equal 0xAABBCCDD, v[0]      # view re-swap to user input
    # parent stored as byte-reversed:
    assert_equal 0xDDCCBBAA, a[0]
    assert_equal 0x01020305, a[1]      # other cells unchanged
  end

  def test_p63_writable_byte_swap_fill_path
    a = CArray.uint32(4).seq!(0)
    v = CAMonOp.__build__(a, BYTE_SWAP_OP_ID)
    v.fill(0x11223344)
    a.dim[0].times do |i|
      assert_equal 0x44332211, a[i]
      assert_equal 0x11223344, v[i]
    end
  end

  # ----- double swap is identity (= involution property) -----

  def test_double_byte_swap_is_identity
    a = CArray.int32(8) { |i| 0x12345678 + i }
    v = CAMonOp.__build__(a, BYTE_SWAP_OP_ID)
    w = CAMonOp.__build__(v, BYTE_SWAP_OP_ID)   # double swap
    assert_equal a.to_a, w.to_a
  end
end

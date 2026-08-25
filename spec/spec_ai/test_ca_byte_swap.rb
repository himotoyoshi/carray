require "test/unit"
require "carray"

# ENHANCE_CASTRUCT Phase B.3a (carray-3.0, 2026-05-21):
# CAByteSwap — a lazy byte-swap view (sibling of CAFake under
# CAView).  CArray#swap_bytes returns a CAByteSwap view (the
# 3.0 breaking change replacing the legacy eager copy); for the
# old eager semantics use `arr.swap_bytes.to_ca`.  CArray#endian
# is the high-level direction-based API with keywords aligned
# with bulk-memory-view: :preserve, :native, :big, :little.

class TestCAByteSwap < Test::Unit::TestCase

  HOST_ENDIAN = (CArray.endian == CA_LITTLE_ENDIAN) ? :little : :big
  HOST_LE     = HOST_ENDIAN == :little

  # --- Primitive types ----------------------------------------------------

  def test_uint16_round_trip
    # Phase 6 P.6.3: numeric byte_swap now returns CAMonOp(byte_swap)
    # via Q11 (E)-style narrow CAByteSwap retain (= struct/data_class
    # 専用).  CAByteSwap class identity for primitive numeric data_types is
    # 3.0 breaking, intentional architectural cleanup.
    a = CArray.uint16(2)
    a[0] = 0x1234; a[1] = 0x5678
    b = a.swap_bytes
    assert_kind_of(CAMonOp, b)    # was CAByteSwap
    assert_equal(0x3412, b[0])
    assert_equal(0x7856, b[1])
    # involution: swap.swap == self
    assert_equal(a.to_a, a.swap_bytes.swap_bytes.to_a)
  end

  def test_uint32_round_trip
    a = CArray.uint32(1)
    a[0] = 0x12345678
    assert_equal(0x78563412, a.swap_bytes[0])
  end

  def test_uint64_round_trip
    a = CArray.uint64(1)
    a[0] = 0x1234_5678_9ABC_DEF0
    assert_equal(0xF0DE_BC9A_7856_3412, a.swap_bytes[0])
  end

  def test_int_signed_round_trip
    a = CArray.int16(1)
    a[0] = 0x0102
    assert_equal(0x0201, a.swap_bytes[0])
  end

  def test_float32_round_trip
    a = CArray.float32(1)
    a[0] = 1.5
    b = a.swap_bytes
    # 1.5 in IEEE754 float32 = 0x3FC00000 (BE bytes) or 00 00 C0 3F (LE).
    # Swap should produce the bit pattern interpreted from reversed bytes.
    refute_equal(1.5, b[0])      # bit pattern reinterpreted
    assert_equal(1.5, b.swap_bytes[0])  # double-swap recovers
  end

  def test_float64_round_trip
    a = CArray.float64(1)
    a[0] = Math::PI
    assert_in_delta(Math::PI, a.swap_bytes.swap_bytes[0])
  end

  # --- Complex types (Zf / Zd, two halves swapped independently) ---------

  def test_cmplx64_round_trip
    a = CArray.cmplx64(1)
    a[0] = Complex(1.5, 2.5)
    assert_equal(Complex(1.5, 2.5), a.swap_bytes.swap_bytes[0])
  end

  def test_cmplx128_round_trip
    a = CArray.cmplx128(1)
    a[0] = Complex(Math::PI, Math::E)
    rt = a.swap_bytes.swap_bytes[0]
    assert_in_delta(Math::PI, rt.real)
    assert_in_delta(Math::E,  rt.imag)
  end

  # --- Class semantics ----------------------------------------------------

  def test_swap_bytes_returns_view_not_copy
    a = CArray.uint32(1)
    a[0] = 0x12345678
    b = a.swap_bytes
    assert_kind_of(CAMonOp, b)    # P.6.3: was CAByteSwap
    # to_ca materialises the view as a free-standing CArray
    eager = b.to_ca
    assert_kind_of(CArray, eager)
    assert_equal(0x78563412, eager[0])
  end

  def test_swap_bytes_rejects_object_type
    a = CArray.object(3)
    assert_raise(CArray::DataTypeError) { a.swap_bytes }
  end

  # --- endian API ---------------------------------------------------------

  def test_endian_preserve_returns_self
    a = CArray.uint32(1)
    assert_same(a, a.endian(:preserve))
  end

  def test_endian_native_returns_self
    a = CArray.uint32(1)
    assert_same(a, a.endian(:native))
  end

  def test_endian_big_returns_self_on_be_host_else_view
    a = CArray.uint32(1)
    if HOST_LE
      assert_kind_of(CAMonOp, a.endian(:big))    # P.6.3: was CAByteSwap
    else
      assert_same(a, a.endian(:big))
    end
  end

  def test_endian_little_returns_self_on_le_host_else_view
    a = CArray.uint32(1)
    if HOST_LE
      assert_same(a, a.endian(:little))
    else
      assert_kind_of(CAMonOp, a.endian(:little))   # P.6.3: was CAByteSwap
    end
  end

  def test_endian_rejects_unknown_keyword
    a = CArray.uint32(1)
    assert_raise(ArgumentError) { a.endian(:network) }
    assert_raise(ArgumentError) { a.endian("big") }
    assert_raise(ArgumentError) { a.endian(:bogus) }
  end

  # --- Struct (CA_FIXLEN + data_class) -----------------------------------

  def test_struct_swap_bytes_round_trip
    s = CArray.struct(pack: 1) { uint16 :x; uint32 :y }
    a = CARecord.new(s, 2)
    a["x"] = 0x1234
    a["y"] = 0xDEADBEEF
    b = a.swap_bytes
    # PROPOSAL_DEPRECATE_LEGACY_DATA_CLASS P.5: swap_bytes on a CARecord
    # parent lifts the CAByteSwap result back into a CARecord so field
    # projection / data_class queries keep working through the view.
    assert_kind_of(CARecord, b)
    # Per-field swap, not whole-record swap
    bx = b["x"]
    by = b["y"]
    assert_equal(0x3412,     bx[0])
    assert_equal(0xEFBEADDE, by[0])
    # Involution
    rt = a.swap_bytes.swap_bytes
    assert_equal(0x1234,     rt["x"][0])
    assert_equal(0xDEADBEEF, rt["y"][0])
  end

  # --- Mask propagation --------------------------------------------------

  def test_mask_shared_with_parent
    a = CArray.uint16(3).tap { |i| i[] = i }
    a.mask = 0
    a.mask[1] = 1
    b = a.swap_bytes
    assert(b.has_mask?)
    assert_equal(a.mask.to_a, b.mask.to_a)
  end

  # --- Write-back via sync -----------------------------------------------

  def test_write_through_view_propagates_to_parent
    # When the view is mutated and then detached, the swapped bytes
    # should be written back to the parent.
    a = CArray.uint16(2)
    a[0] = 0x1234; a[1] = 0x5678
    b = a.swap_bytes
    # Reading from b should give swapped values
    assert_equal(0x3412, b[0])
    # Writing through b — semantics: b[0] is interpreted as host;
    # the byte representation in parent is the host bytes for b[0]
    # then swapped.  swap.swap == identity.
    b[0] = 0xABCD
    # The parent now has bytes that, when swapped, give 0xABCD
    # i.e., parent's bytes are the swap of 0xABCD = 0xCDAB.
    assert_equal(0xCDAB, a[0])
    # And reading b[0] back gives the round-trip value (still
    # 0xABCD since the view re-swaps).
    assert_equal(0xABCD, a.swap_bytes[0])
  end

end

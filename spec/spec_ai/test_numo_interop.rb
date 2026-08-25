require "test/unit"
require "carray"

# End-to-end interop tests between CArray and Numo::NArray via the
# MemoryView protocol.  Skipped automatically if numo-narray or
# numo-narray-memoryview are not installed.
#
# This file is intentionally kept in sync with the equivalent file on
# the numo-narray-memoryview side (test/test_carray_interop.rb) so the
# same data patterns are exercised in both directions.

begin
  require "numo/narray"
  require "numo/narray/memoryview"
rescue LoadError => e
  warn "Skipping test_numo_interop: #{e.message}"
  return
end

class TestNumoInterop < Test::Unit::TestCase

  # ============================================================
  # 1. CArray -> Numo (copy via Numo::NArray.from_memory_view)
  # ============================================================

  def test_carray_to_numo_from_int32
    ca = CArray.int32(3, 4).seq
    na = Numo::NArray.from_memory_view(ca)
    assert_equal(Numo::Int32, na.class)
    assert_equal([3, 4], na.shape)
    assert_equal(ca.to_a, na.to_a)
  end

  def test_carray_to_numo_from_is_independent_copy
    ca = CArray.int32(5).seq
    na = Numo::NArray.from_memory_view(ca)
    ca[0] = -999
    assert_equal(0, na[0], "from_memory_view must produce an independent copy")
  end

  # ============================================================
  # 2. CArray -> Numo (zero-copy via wrap_memory_view)
  # ============================================================

  def test_carray_to_numo_wrap_shares_memory
    ca = CArray.float64(5).seq(0.5, 1.5)
    na = Numo::NArray.wrap_memory_view(ca)
    assert_equal(ca.to_a, na.to_a)
    ca[2] = 99.5
    assert_equal(99.5, na[2], "wrap_memory_view shares memory")
  end

  # ============================================================
  # 3. Numo -> CArray (copy via from_memory_view)
  # ============================================================

  def test_numo_to_carray_from_int32
    na = Numo::Int32.new(2, 3).seq
    ca = CArray.from_memory_view(na)
    assert_equal(CArray, ca.class)
    assert_equal([2, 3], ca.shape)
    assert_equal(CA_INT32, ca.data_type)
    assert_equal(na.to_a, ca.to_a)
  end

  def test_numo_to_carray_from_is_independent_copy
    na = Numo::Int32.new(4).seq
    ca = CArray.from_memory_view(na)
    na[0] = -999
    assert_equal(0, ca[0])
  end

  # ============================================================
  # 4. Numo -> CArray (zero-copy via wrap_memory_view)
  # ============================================================

  def test_numo_to_carray_wrap_shares_memory
    na = Numo::DFloat.new(5).seq
    ca = CArray.wrap_memory_view(na)
    assert_equal(CAWrap, ca.class)
    assert_equal(na.to_a, ca.to_a)
    ca[1] = 99.0
    assert_equal(99.0, na[1])
  end

  # ============================================================
  # 5. Round-trip zero-copy chain (identity preservation)
  # ============================================================

  def test_roundtrip_carray_numo_carray_wrap
    src = CArray.float64(4).seq(1.0, 2.0)
    na  = Numo::NArray.wrap_memory_view(src)
    back = CArray.wrap_memory_view(na)
    back[1] = -1.0
    assert_equal(-1.0, src[1], "full zero-copy chain must share memory all the way through")
  end

  # ============================================================
  # 6. data_type matrix: all 10 supported numeric data_types bidirectional
  # ============================================================

  DTYPE_PAIRS = [
    [:int8,    CA_INT8,    Numo::Int8],
    [:uint8,   CA_UINT8,   Numo::UInt8],
    [:int16,   CA_INT16,   Numo::Int16],
    [:uint16,  CA_UINT16,  Numo::UInt16],
    [:int32,   CA_INT32,   Numo::Int32],
    [:uint32,  CA_UINT32,  Numo::UInt32],
    [:int64,   CA_INT64,   Numo::Int64],
    [:uint64,  CA_UINT64,  Numo::UInt64],
    [:float32, CA_FLOAT32, Numo::SFloat],
    [:float64, CA_FLOAT64, Numo::DFloat],
  ].freeze

  def test_data_type_matrix_carray_to_numo
    DTYPE_PAIRS.each do |ca_dt_sym, _ca_dt, numo_klass|
      ca = CArray.send(ca_dt_sym, 4).seq
      na = Numo::NArray.from_memory_view(ca)
      assert_equal(numo_klass, na.class, "CArray.#{ca_dt_sym} -> #{numo_klass}: class")
      assert_equal(ca.to_a, na.to_a,     "CArray.#{ca_dt_sym} -> #{numo_klass}: data")
    end
  end

  def test_data_type_matrix_numo_to_carray
    DTYPE_PAIRS.each do |_ca_dt_sym, ca_dt, numo_klass|
      na = numo_klass.new(4).seq
      ca = CArray.from_memory_view(na)
      assert_equal(ca_dt, ca.data_type, "#{numo_klass} -> CArray: data_type")
      assert_equal(na.to_a, ca.to_a,    "#{numo_klass} -> CArray: data")
    end
  end

  # ============================================================
  # 7. Strided sources -- supported by from_, rejected by wrap_
  # ============================================================

  def test_numo_strided_to_carray_from
    # Numo transposed -> strided source; from_memory_view must accept it
    na = Numo::Int32.new(2, 3).seq
    tr = na.transpose
    ca = CArray.from_memory_view(tr)
    assert_equal(tr.to_a, ca.to_a)
  end

  def test_carray_block_to_numo_from
    # CABlock strided subset -> Numo.from_memory_view, end-to-end strided
    # copy. Both producers (CArray) and consumers (Numo) advertise STRIDES
    # since numo-narray-memoryview rolled out its strided from_ support.
    ca = CArray.int32(5, 5).seq
    bl = ca[1..3, 1..3]
    na = Numo::NArray.from_memory_view(bl)
    assert_equal(bl.to_a, na.to_a)
  end

  def test_carray_block_stepped_to_numo_from
    # Step > 1 on both dims: validates the row-major gather on the Numo
    # side handles non-unit strides correctly.
    ca = CArray.int32(5, 5).seq
    bl = ca[[0, 3, 2], [0, 3, 2]]   # 3x3 every-other
    na = Numo::NArray.from_memory_view(bl)
    assert_equal(bl.to_a, na.to_a)
  end

  def test_strided_block_to_numo_wrap_zero_copy
    # With PEP 3118 byte_size alignment on the CArray producer, Numo's
    # consumer side now accepts strided sources zero-copy.  (Earlier
    # versions rejected this on byte_size mismatch; that path is gone.)
    ca = CArray.int32(5, 5).seq
    bl = ca[[0, 3, 2], [0, 3, 2]]   # 3x3 strided
    na = Numo::NArray.wrap_memory_view(bl)
    assert_equal(bl.to_a, na.to_a)
  end

  def test_numo_strided_to_carray_wrap_returns_castride
    # Previously rejected; with the CAStride wrap path a strided
    # Numo source becomes a CAStride view.
    na = Numo::Int32.new(2, 3).seq
    tr = na.transpose
    ca = CArray.wrap_memory_view(tr)
    assert_kind_of(CAStride, ca)
    assert_equal(tr.to_a, ca.to_a)
  end

  # ============================================================
  # 8. CARefer (contiguous reshape) round-trips cleanly
  # ============================================================

  def test_carefer_to_numo
    ca = CArray.int32(12).seq
    rf = ca.reshape(3, 4)
    na = Numo::NArray.from_memory_view(rf)
    assert_equal([3, 4], na.shape)
    assert_equal(rf.to_a, na.to_a)
  end
end

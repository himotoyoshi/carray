require "test/unit"
require "carray"

# Interop tests between CArray and bulk-memory-view (BMV).
# Covers:
#   - CArray as a MemoryView producer consumed by BMV.from / BMV.wrap
#   - BMV as a producer consumed by CArray.from_memory_view / wrap_memory_view
#   - Round-trips across various data_types and shapes
#   - Write-through via zero-copy aliasing
#   - Rejection of masked CArrays
# Skipped if bulk-memory-view is not installed.

begin
  require "bulk-memory-view"
rescue LoadError
  warn "Skipping test_bmv_interop: bulk-memory-view not installed."
  return
end

class TestBMVInterop < Test::Unit::TestCase

  # --- CArray as producer: BMV.from (snapshot copy) -----------------------

  def test_bmv_from_entity
    ca = CArray.int32(3, 4).seq
    bmv = BulkMemoryView.from(ca)
    assert_equal([3, 4], bmv.shape)
    assert_equal("i", bmv.format)
    assert_equal(4, bmv.item_size)
    assert_equal(48, bmv.byte_size)
    # snapshot is independent
    ca[0, 0] = 999
    ca2 = CArray.wrap_memory_view(bmv)
    assert_equal(0, ca2[0, 0])
  end

  def test_bmv_from_castride_col_slice
    ca = CArray.int32(3, 4).seq
    col = ca[nil, 1..2]               # CABlock / CAStride, non-contiguous
    bmv = BulkMemoryView.from(col)    # must materialise to row-major
    assert_equal([3, 2], bmv.shape)
    snap = CArray.wrap_memory_view(bmv)
    assert_equal(col.to_a, snap.to_a)
  end

  def test_bmv_from_transposed
    ca = CArray.int32(3, 4).seq
    bmv = BulkMemoryView.from(ca.transpose)
    assert_equal([4, 3], bmv.shape)
    snap = CArray.wrap_memory_view(bmv)
    assert_equal(ca.transpose.to_a, snap.to_a)
  end

  # --- CArray as producer: BMV.wrap (zero-copy alias) ---------------------

  def test_bmv_wrap_entity_is_borrowed
    ca = CArray.float64(2, 3).seq
    bmv = BulkMemoryView.wrap(ca)
    assert_equal(true, bmv.borrowed?)
    assert_equal([2, 3], bmv.shape)
    assert_equal([24, 8], bmv.strides)
  end

  def test_bmv_wrap_entity_round_trip_through_wrap_memory_view
    ca = CArray.float64(2, 3).seq
    bmv = BulkMemoryView.wrap(ca)
    ca2 = CArray.wrap_memory_view(bmv)    # CArray -> BMV -> CArray, all zero-copy
    ca2[1, 2] = -7.0
    assert_equal(-7.0, ca[1, 2])           # write-through reaches original
  end

  def test_bmv_wrap_castride_col_slice_zero_copy_write_through
    ca = CArray.int32(3, 4).seq
    col = ca[nil, 1..2]                   # non-contig CAStride
    bmv = BulkMemoryView.wrap(col)        # BMV alias of the strided view
    assert_equal([3, 2], bmv.shape)
    ca2 = CArray.wrap_memory_view(bmv)    # re-wrap as CArray
    ca2[0, 0] = 999
    assert_equal(999, ca[0, 1])           # write reaches the original entity
  end

  # --- BMV.new as producer: CArray reads / writes -------------------------

  def test_wrap_memory_view_bmv_new
    bmv = BulkMemoryView.new([2, 3], format: "d")
    bmv.write([1.0, 2, 3, 4, 5, 6].pack("d*"))
    ca = CArray.wrap_memory_view(bmv)
    assert_kind_of(CAWrap, ca)
    assert_equal([[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]], ca.to_a)
  end

  def test_from_memory_view_bmv_new_is_independent_copy
    bmv = BulkMemoryView.new([4], format: "l")
    bmv.write([10, 20, 30, 40].pack("l*"))
    ca = CArray.from_memory_view(bmv)
    assert_kind_of(CArray, ca)
    # mutate the copy; BMV must be untouched
    ca[0] = -1
    ca2 = CArray.wrap_memory_view(bmv)
    assert_equal(10, ca2[0])
  end

  # --- Dtype matrix --------------------------------------------------------

  # Outbound spellings follow ruby/memory_view.h, so the widths below 32 bits
  # are Ruby's ('c' / 'C' / 's' / 'S'), not PEP 3118's ('b' / 'B' / 'h' / 'H').
  # The two vocabularies agree from 32 bits up.
  DTYPES = {
    int8:    [:int8,    "c"],
    uint8:   [:uint8,   "C"],
    int16:   [:int16,   "s"],
    uint16:  [:uint16,  "S"],
    int32:   [:int32,   "i"],
    uint32:  [:uint32,  "I"],
    int64:   [:int64,   "q"],
    uint64:  [:uint64,  "Q"],
    float32: [:float32, "f"],
    float64: [:float64, "d"],
  }

  DTYPES.each do |name, (type, fmt)|
    define_method("test_round_trip_#{name}") do
      ca = CArray.send(type, 2, 3).seq
      bmv = BulkMemoryView.from(ca)
      assert_equal(fmt, bmv.format, "format mismatch for #{name}")
      ca2 = CArray.from_memory_view(bmv, data_type: type)
      assert_equal(ca.to_a, ca2.to_a, "round-trip mismatch for #{name}")
    end
  end

  # --- 1D and 3D shapes ---------------------------------------------------

  def test_round_trip_1d
    ca = CArray.float64(8).seq
    bmv = BulkMemoryView.from(ca)
    assert_equal([8], bmv.shape)
    assert_equal(ca.to_a, CArray.from_memory_view(bmv).to_a)
  end

  def test_round_trip_3d
    ca = CArray.float64(2, 3, 4).seq
    bmv = BulkMemoryView.from(ca)
    assert_equal([2, 3, 4], bmv.shape)
    assert_equal(ca.to_a, CArray.from_memory_view(bmv).to_a)
  end

  # --- v1.1: PEP 3118 canonical for bool / complex through BMV ------------
  # BMV delegates format parsing to rb_memory_view_parse_item_format,
  # which is PEP 3118-aware (see MEMORYVIEW_FORMAT.md §0).  These tests
  # verify CArray's v1.1 producer emits symbols that BMV passes through
  # untouched and that round-trip back into CArray with correct data_type.

  def test_round_trip_boolean_v11
    ca = CArray.boolean(5)
    [1, 0, 1, 1, 0].each_with_index { |v, i| ca[i] = v }
    bmv = BulkMemoryView.from(ca)
    assert_equal("?", bmv.format)
    assert_equal(1, bmv.item_size)
    snap = CArray.from_memory_view(bmv)
    assert_equal(CA_BOOLEAN, snap.data_type)
    assert_equal(ca.to_a, snap.to_a)
  end

  def test_round_trip_complex64_v11
    ca = CArray.cmplx64(4)
    [Complex(1, 2), Complex(3, 4), Complex(-1, -2), Complex(0, 0)].each_with_index { |v, i| ca[i] = v }
    bmv = BulkMemoryView.from(ca)
    assert_equal("Zf", bmv.format)
    assert_equal(8, bmv.item_size)
    snap = CArray.from_memory_view(bmv)
    assert_equal(CA_CMPLX64, snap.data_type)
    assert_equal(ca.to_a, snap.to_a)
  end

  def test_round_trip_complex128_v11
    ca = CArray.cmplx128(3)
    [Complex(1.5, -2.5), Complex(0.0, 3.14), Complex(-7.0, 0.0)].each_with_index { |v, i| ca[i] = v }
    bmv = BulkMemoryView.from(ca)
    assert_equal("Zd", bmv.format)
    assert_equal(16, bmv.item_size)
    snap = CArray.from_memory_view(bmv)
    assert_equal(CA_CMPLX128, snap.data_type)
    assert_equal(ca.to_a, snap.to_a)
  end

  # --- Mask rejection (CArray side) ---------------------------------------

  def test_bmv_from_rejects_masked_carray
    ca = CArray.int32(3, 4).seq
    ca.mask = 0
    ca.mask[0, 0] = 1
    assert_raise(TypeError) { BulkMemoryView.from(ca) }
    assert_raise(TypeError) { BulkMemoryView.wrap(ca) }
  end

  def test_bmv_accepts_value_view_of_masked
    # `.value` returns a mask-ignoring CARefer; this should be exportable.
    ca = CArray.int32(3, 4).seq
    ca.mask = 0
    ca.mask[0, 0] = 1
    bmv = BulkMemoryView.from(ca.value)
    assert_equal([3, 4], bmv.shape)
    snap = CArray.wrap_memory_view(bmv)
    assert_equal(0, snap[0, 0])   # underlying value preserved
  end
end

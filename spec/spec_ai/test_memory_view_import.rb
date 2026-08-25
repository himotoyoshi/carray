require "test/unit"
require "carray"

# Phase 4+5: importer API.  Two methods mirroring numo-narray-memoryview:
#   - CArray.from_memory_view(obj)  -> CArray  (independent copy)
#   - CArray.wrap_memory_view(obj)  -> CAWrap  (zero-copy, shared memory)
# These tests use other CArrays as producers to verify the import path
# end-to-end.

class TestMemoryViewImport < Test::Unit::TestCase

  # ============================================================
  # wrap_memory_view: zero-copy
  # ============================================================

  def test_wrap_from_entity_int32
    ca = CArray.int32(3, 4).seq
    ca2 = CArray.wrap_memory_view(ca)
    assert_kind_of(CAWrap, ca2)
    assert_equal([3, 4], ca2.shape)
    assert_equal(CA_INT32, ca2.data_type)
    assert_equal(ca.to_a, ca2.to_a)
  end

  def test_wrap_from_float64
    ca = CArray.float64(5).seq(0.5, 1.5)
    ca2 = CArray.wrap_memory_view(ca)
    assert_equal(CA_FLOAT64, ca2.data_type)
    assert_equal(ca.to_a, ca2.to_a)
  end

  def test_wrap_from_int64
    ca = CArray.int64(7).seq
    ca2 = CArray.wrap_memory_view(ca)
    assert_equal(CA_INT64, ca2.data_type)
    assert_equal(ca.to_a, ca2.to_a)
  end

  def test_wrap_from_uint8
    ca = CArray.uint8(10).seq
    ca2 = CArray.wrap_memory_view(ca)
    assert_equal(CA_UINT8, ca2.data_type)
    assert_equal(ca.to_a, ca2.to_a)
  end

  # v1.1: PEP 3118 canonical for bool / complex.  Producer emits
  # '?' / 'Zf' / 'Zd'; consumer dispatches via the v1.1 §3.2 table.
  def test_wrap_from_boolean_v11_canonical
    ca = CArray.boolean(4)
    [1, 0, 1, 0].each_with_index { |v, i| ca[i] = v }
    ca2 = CArray.wrap_memory_view(ca)
    assert_equal(CA_BOOLEAN, ca2.data_type)
    assert_equal(ca.to_a, ca2.to_a)
  end

  def test_wrap_from_complex64_v11_canonical
    ca = CArray.cmplx64(3)
    [Complex(0, 0.5), Complex(1, 1.5), Complex(2, 2.5)].each_with_index { |v, i| ca[i] = v }
    ca2 = CArray.wrap_memory_view(ca)
    assert_equal(CA_CMPLX64, ca2.data_type)
    assert_equal(ca.to_a, ca2.to_a)
  end

  def test_wrap_from_complex128_v11_canonical
    ca = CArray.cmplx128(3)
    [Complex(0.0, 0.0), Complex(1.5, -1.0), Complex(3.0, -2.0)].each_with_index { |v, i| ca[i] = v }
    ca2 = CArray.wrap_memory_view(ca)
    assert_equal(CA_CMPLX128, ca2.data_type)
    assert_equal(ca.to_a, ca2.to_a)
  end

  def test_wrap_shares_memory_bidirectional
    ca = CArray.int32(5).seq
    ca2 = CArray.wrap_memory_view(ca)
    ca2[2] = -999
    assert_equal(-999, ca[2], "writing through the wrapper must reach the source")
    ca[3] = -888
    assert_equal(-888, ca2[3], "writing through the source must be visible via the wrapper")
  end

  def test_wrap_from_carefer
    ca = CArray.int32(12).seq
    rf = ca.reshape(3, 4)
    ca2 = CArray.wrap_memory_view(rf)
    assert_equal([3, 4], ca2.shape)
    assert_equal(rf.to_a, ca2.to_a)
  end

  def test_wrap_propagates_readonly
    ca = CArray.int32(3).seq.freeze
    assert_true(ca.read_only?)
    ca2 = CArray.wrap_memory_view(ca)
    assert_true(ca2.read_only?)
  end

  def test_wrap_source_anchored_via_ivar
    ca = CArray.int32(100).seq
    ca2 = CArray.wrap_memory_view(ca)
    ca = nil
    GC.start
    GC.start
    assert_equal((0..99).to_a, ca2.to_a)
  end

  def test_wrap_gc_release_stable
    100.times do
      src = CArray.int32(50).seq
      wrap = CArray.wrap_memory_view(src)
      wrap[0] = -1
      assert_equal(-1, src[0])
    end
    GC.start
    GC.start
  end

  # ============================================================
  # from_memory_view: copy
  # ============================================================

  def test_from_returns_owned_carray
    ca = CArray.int32(3, 4).seq
    ca2 = CArray.from_memory_view(ca)
    # An owned CArray (not CAWrap).  The exact class is CArray.
    assert_equal(CArray, ca2.class)
    assert_equal([3, 4], ca2.shape)
    assert_equal(ca.to_a, ca2.to_a)
  end

  def test_from_is_independent_copy
    ca = CArray.int32(5).seq
    ca2 = CArray.from_memory_view(ca)
    # Mutate source; the copy must NOT change.
    ca[0] = -777
    assert_equal(0, ca2[0], "from_memory_view must produce an independent copy")
    # Mutate copy; the source must NOT change.
    ca2[1] = -888
    assert_equal(1, ca[1])
  end

  def test_from_works_after_source_freed
    src = CArray.float64(10).seq(0.5, 0.25)
    expected = src.to_a
    ca = CArray.from_memory_view(src)
    src = nil
    GC.start
    GC.start
    # The independent copy must remain intact.
    assert_equal(expected, ca.to_a)
  end

  def test_from_data_type_matrix
    [
      [:int8,  CA_INT8],
      [:uint8, CA_UINT8],
      [:int16, CA_INT16],
      [:uint16, CA_UINT16],
      [:int32, CA_INT32],
      [:uint32, CA_UINT32],
      [:int64, CA_INT64],
      [:uint64, CA_UINT64],
      [:float32, CA_FLOAT32],
      [:float64, CA_FLOAT64],
    ].each do |dt, ca_dt|
      ca = CArray.send(dt, 4).seq
      ca2 = CArray.from_memory_view(ca)
      assert_equal(ca_dt, ca2.data_type, "from_memory_view data_type #{dt}")
      assert_equal(ca.to_a, ca2.to_a, "from_memory_view values #{dt}")
    end
  end

  def test_from_does_not_propagate_readonly
    # The copy is a fresh owned buffer; readonly status of the source
    # is not inherited.
    ca = CArray.int32(3).seq.freeze
    ca2 = CArray.from_memory_view(ca)
    assert_false(ca2.read_only?, "owned copy is writable")
  end

  # ============================================================
  # strided sources
  # ============================================================

  def test_from_strided_cablock_subset
    ca = CArray.int32(5, 5).seq
    bl = ca[1..3, 1..3]   # 3x3 subset; strided
    ca2 = CArray.from_memory_view(bl)
    assert_equal(CArray, ca2.class)
    assert_equal([3, 3], ca2.shape)
    assert_equal(bl.to_a, ca2.to_a)
  end

  def test_from_strided_stepped_block
    ca = CArray.int32(10).seq
    bl = ca[[0, 5, 2]]   # every other element: [0, 2, 4, 6, 8]
    ca2 = CArray.from_memory_view(bl)
    assert_equal([5], ca2.shape)
    assert_equal([0, 2, 4, 6, 8], ca2.to_a)
  end

  def test_from_strided_2d_stepped
    ca = CArray.int32(5, 5).seq
    bl = ca[[0, 3, 2], [0, 3, 2]]   # 3x3, every other element
    ca2 = CArray.from_memory_view(bl)
    assert_equal(bl.to_a, ca2.to_a)
  end

  def test_from_transposed_virtual
    ca = CArray.int32(2, 3).seq
    tr = ca.transpose   # CATranspose virtual, strides permuted
    ca2 = CArray.from_memory_view(tr)
    assert_equal([3, 2], ca2.shape)
    assert_equal(tr.to_a, ca2.to_a)
  end

  def test_from_farray_column_major
    ca = CArray.int32(2, 3).seq
    fa = ca.farray   # CAFarray, column-major
    ca2 = CArray.from_memory_view(fa)
    # The copy is row-major in the wrapper's own shape; values match fa
    assert_equal([3, 2], ca2.shape)
    assert_equal(fa.to_a, ca2.to_a)
  end

  def test_from_strided_independence
    ca = CArray.int32(5, 5).seq
    bl = ca[1..3, 1..3]
    ca2 = CArray.from_memory_view(bl)
    # Copy must be independent of the source
    ca[0, 0] = -1
    ca[2, 2] = -999
    expected = [[6, 7, 8], [11, 12, 13], [16, 17, 18]]   # bl[0..2,0..2] = ca[1..3,1..3] before mutation
    # After mutation, ca[2,2] = -999 was previously 12, so bl[1,1] now reads -999
    # but our copy ca2 should still be the OLD value (12)
    assert_equal(12, ca2[1, 1], "from_memory_view copy must be independent")
  end

  def test_wrap_strided_block_returns_castride
    # Previously rejected; with the CAStride wrap path the strided
    # producer is accepted and returned as a CAStride.
    ca = CArray.int32(5, 5).seq
    bl = ca[[0, 3, 2], [0, 3, 2]]   # strided
    rewrap = CArray.wrap_memory_view(bl)
    assert_kind_of(CAStride, rewrap)
    assert_equal(bl.to_a, rewrap.to_a)
  end

  def test_wrap_transposed_returns_castride
    ca = CArray.int32(2, 3).seq
    tr = ca.transpose
    rewrap = CArray.wrap_memory_view(tr)
    assert_kind_of(CAStride, rewrap)
    assert_equal(tr.to_a, rewrap.to_a)
  end

  def test_wrap_contiguous_block_accepted
    # A block that ends up contiguous (full inner rows) IS wrappable.
    ca = CArray.int32(4, 5).seq
    bl = ca[1..2, 0..4]   # 2 full rows of 5 = row-major contiguous
    ca2 = CArray.wrap_memory_view(bl)
    assert_kind_of(CAWrap, ca2)
    assert_equal(bl.to_a, ca2.to_a)
  end

  # ============================================================
  # error cases (shared between both methods)
  # ============================================================

  def test_wrap_non_memory_view_raises
    assert_raise(ArgumentError) { CArray.wrap_memory_view("hello") }
  end

  def test_from_non_memory_view_raises
    assert_raise(ArgumentError) { CArray.from_memory_view("hello") }
  end

  def test_wrap_object_carray_raises
    assert_raise(ArgumentError) { CArray.wrap_memory_view(CArray.object(3)) }
  end

  def test_from_object_carray_raises
    assert_raise(ArgumentError) { CArray.from_memory_view(CArray.object(3)) }
  end

  def test_wrap_masked_raises
    ca = CArray.int32(3).seq
    ca.mask = [1, 0, 0]
    assert_raise(ArgumentError) { CArray.wrap_memory_view(ca) }
  end

  def test_from_masked_raises
    ca = CArray.int32(3).seq
    ca.mask = [1, 0, 0]
    assert_raise(ArgumentError) { CArray.from_memory_view(ca) }
  end
end

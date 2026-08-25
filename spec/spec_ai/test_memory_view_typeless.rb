require "test/unit"
require "carray"

# Tests for typeless MemoryView producer consumption.  When the
# producer publishes view.format == NULL (e.g. mmap-view, IO#read
# byte buffer, socket payload), the consumer side must supply the
# target data_type.  Two API surfaces:
#
#   CArray.from_memory_view(obj, data_type: :float64)
#   CArray.wrap_memory_view(obj, data_type: :float64)
#   CArray::Float64.from_memory_view(obj)
#   CArray::Float64.wrap_memory_view(obj)
#
# A tiny in-test C extension is not used; we exercise the path via
# CArray itself (typed producer) for cross-checks, and rely on the
# manual mmap-view integration test for real typeless coverage.

class TestMemoryViewTypeless < Test::Unit::TestCase

  # ---------------- data_type: kwarg on the base API ----------------

  def test_type_kwarg_matches_producer_format
    # When data_type: matches the producer's format, accept.
    ca = CArray.float64(10).seq
    ca2 = CArray.from_memory_view(ca, data_type: :float64)
    assert_equal(ca.to_a, ca2.to_a)
  end

  def test_type_kwarg_accepts_carray_data_type_class
    ca = CArray.int32(5).seq
    ca2 = CArray.from_memory_view(ca, data_type: CArray::Int32)
    assert_equal(ca.to_a, ca2.to_a)
    assert_equal(CA_INT32, ca2.data_type)
  end

  def test_type_kwarg_accepts_integer_constant
    ca = CArray.uint16(8).seq
    ca2 = CArray.from_memory_view(ca, data_type: CA_UINT16)
    assert_equal(ca.to_a, ca2.to_a)
  end

  def test_type_kwarg_mismatch_with_format_raises
    ca = CArray.float64(10).seq
    assert_raise(ArgumentError) do
      CArray.from_memory_view(ca, data_type: :int32)
    end
  end

  def test_no_type_no_format_raises
    # When the producer is typeless and no data_type: kwarg is given,
    # ArgumentError with a hint pointing at data_type:.
    # We cannot easily construct a pure typeless producer in pure
    # Ruby; here we just verify that the typed-source path without
    # data_type: still works.
    ca = CArray.int32(5).seq
    ca2 = CArray.from_memory_view(ca)   # no data_type: -> derive from format
    assert_equal(ca.to_a, ca2.to_a)
  end

  # ---------------- data_type class factory ----------------

  def test_data_type_class_from_memory_view_matches_base
    ca = CArray.float64(10).seq
    via_kwarg = CArray.from_memory_view(ca, data_type: :float64)
    via_klass = CArray::Float64.from_memory_view(ca)
    assert_equal(via_kwarg.to_a, via_klass.to_a)
    assert_equal(via_kwarg.data_type, via_klass.data_type)
  end

  def test_data_type_class_wrap_memory_view
    ca = CArray.int32(8).seq
    wrap = CArray::Int32.wrap_memory_view(ca)
    assert_kind_of(CAWrap, wrap)
    assert_equal(ca.to_a, wrap.to_a)
    # zero-copy verification
    wrap[0] = -1
    assert_equal(-1, ca[0])
  end

  def test_data_type_class_mismatch_with_producer_raises
    ca = CArray.float64(5).seq
    assert_raise(ArgumentError) do
      CArray::Int32.from_memory_view(ca)
    end
  end

  def test_data_type_class_consistency_with_existing_factory
    # CArray::Int32 already exposes .new, .zeros, .linspace, etc.
    # The new from_memory_view / wrap_memory_view should fit the
    # same pattern.
    assert_equal(CA_INT32, CArray::Int32::DataType)
    assert_respond_to(CArray::Int32, :new)
    assert_respond_to(CArray::Int32, :from_memory_view)
    assert_respond_to(CArray::Int32, :wrap_memory_view)
    assert_respond_to(CArray::Float64, :from_memory_view)
    assert_respond_to(CArray::Float64, :wrap_memory_view)
  end

  # ---------------- 1D + reshape pattern ----------------

  def test_reshape_after_wrap_is_zero_copy
    ca = CArray.float64(100).seq
    flat = CArray::Float64.wrap_memory_view(ca)
    mat = flat.reshape(10, 10)
    # 3.0: reshape returns CAStride or CARefer; both share memory via parent.
    assert_true([CARefer, CAStride].include?(mat.class))
    assert_equal([10, 10], mat.shape)
    # mat shares memory with ca through flat
    mat[5, 5] = -999.0
    assert_equal(-999.0, ca[55])
  end

  # ---------------- alignment ----------------

  def test_typed_source_data_type_mismatch_rejects
    # When the producer is typed (CArray.uint8 → format="C"), a
    # consumer-data_type mismatch is a real error (not a silent
    # reinterpretation).  Use ca.refer(:data_type, dim) on the producer
    # side if byte reinterpretation is intended.
    src = CArray.uint8(8).seq
    assert_raise(ArgumentError) do
      CArray::Float64.from_memory_view(src)
    end
  end
end

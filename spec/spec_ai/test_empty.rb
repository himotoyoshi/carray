# Smoke for CArray.empty (= uninit alloc), added in the
# data_type_extension.rb 'empty' surface.  The point is shape /
# dtype / class dispatch parity with CArray.zeros et al.; the
# values are intentionally garbage, so we don't assert on contents
# (other than the CA_OBJECT fallback which IS deterministic).

require "test/unit"
require "carray"

class TestCArrayEmpty < Test::Unit::TestCase

  # --- shape forms

  def test_empty_splat_shape
    a = CArray.empty(2, 3)
    assert_equal [2, 3], a.shape
    assert_equal CA_FLOAT64, a.data_type   # default
  end

  def test_empty_array_shape
    a = CArray.empty([4, 5])
    assert_equal [4, 5], a.shape
  end

  def test_empty_1d_int_arg
    a = CArray.empty(7)
    assert_equal [7], a.shape
  end

  # --- typed class dispatch

  def test_typed_class_int32
    a = CArray::Int32.empty(3, 4)
    assert_equal [3, 4], a.shape
    assert_equal CA_INT32, a.data_type
  end

  def test_typed_class_float32
    a = CArray::Float32.empty([5])
    assert_equal [5], a.shape
    assert_equal CA_FLOAT32, a.data_type
  end

  # --- CA_OBJECT fallback: silently zero-VALUE init (= GC safety),
  # so reading garbage is impossible; we verify the cells are the
  # canonical zero VALUE (= SIZE2NUM(0)).
  def test_object_dtype_silent_zero_value_init
    a = CArray::Object.empty(3)
    assert_equal [3], a.shape
    assert_equal CA_OBJECT, a.data_type
    a.each { |v| assert_equal 0, v }
  end

  # --- caller-fills-it round trip

  def test_caller_fills_then_reads
    a = CArray::Int32.empty(5)
    a[] = CA_INT([10, 20, 30, 40, 50])
    assert_equal [10, 20, 30, 40, 50], a.to_a
  end

end

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

  # ------------------------------------------------------------------
  # CArray.empty(data_type, dim) -- carray's own spelling, = CArray.new
  # without the fill.  Contents stay unasserted (undefined by contract);
  # what is pinned is that every argument is read the way CArray.new
  # reads it, down to the wording of the refusals.
  # ------------------------------------------------------------------

  def test_type_and_shape
    a = CArray.empty(:int64, [3, 4])
    assert_equal CA_INT64, a.data_type
    assert_equal [3, 4], a.shape
  end

  def test_type_spelled_as_constant_symbol_and_string
    assert_equal CA_INT32, CArray.empty(CA_INT32, [4]).data_type
    assert_equal CA_INT32, CArray.empty(:int32, [4]).data_type
    assert_equal CA_INT32, CArray.empty("int32", [4]).data_type
  end

  def test_fixlen_takes_bytes
    a = CArray.empty(:fixlen, [3], bytes: 8)
    assert_equal CA_FIXLEN, a.data_type
    assert_equal 8, a.bytes
    assert_equal [3], a.shape
  end

  # CA_OBJECT cannot be left undefined (the GC walks it), so it keeps
  # the zero-VALUE init -- the one case whose contents are asserted.
  def test_object_type_is_zero_value_init
    a = CArray.empty(:object, [3])
    assert_equal CA_OBJECT, a.data_type
    a.each { |v| assert_equal 0, v }
  end

  # --- refusals

  def test_class_first_argument_refused_in_the_words_of_new
    from_new = assert_raise(ArgumentError) { CArray.new(String, [4]) }
    from_empty = assert_raise(ArgumentError) { CArray.empty(String, [4]) }
    assert_equal from_new.message, from_empty.message
  end

  def test_block_is_refused
    assert_raise(ArgumentError) { CArray.empty(:int64, [3]) { 1 } }
  end

  def test_block_is_refused_on_the_compatibility_form_too
    assert_raise(ArgumentError) { CArray.empty(2, 3) { 1 } }
  end

  # --- parity with CArray.new at the edges

  # An Integer first argument reaches an internal numbering that is not
  # part of the public API (the CA_* constants have been Symbols since
  # 3.0), so what it yields is not pinned here -- only that empty reads
  # it as new reads it, whichever way that falls.  Before this form
  # existed the pair was read as a shape and raised TypeError.
  def test_integer_first_argument_matches_new
    from_new = begin
                 CArray.new(3, [4])
               rescue Exception => e
                 e
               end
    from_empty = begin
                   CArray.empty(3, [4])
                 rescue Exception => e
                   e
                 end
    if from_new.is_a?(Exception)
      assert_equal from_new.class, from_empty.class
      assert_equal from_new.message, from_empty.message
    else
      assert_equal from_new.data_type, from_empty.data_type
      assert_equal from_new.shape, from_empty.shape
    end
  end

  def test_empty_dim_refused_as_new_refuses_it
    from_new = assert_raise(RuntimeError) { CArray.new(:int64, []) }
    from_empty = assert_raise(RuntimeError) { CArray.empty(:int64, []) }
    assert_equal from_new.message, from_empty.message
  end

  # --- the compatibility form still reaches DataTypeExtension#empty

  def test_compatibility_forms_unchanged
    assert_equal [2, 3], CArray.empty(2, 3).shape
    assert_equal CA_FLOAT64, CArray.empty(2, 3).data_type
    assert_equal [2, 3], CArray.empty([2, 3]).shape
    assert_equal [3], CArray::Int64.empty(3).shape
    assert_equal CA_INT64, CArray::Int64.empty(3).data_type
  end

  # The routing in construct.rb hands the compatibility form on with
  # `super`, which only has somewhere to go while this holds.
  def test_data_type_extension_is_still_in_the_singleton_ancestry
    assert_include CArray.singleton_class.ancestors, CArray::DataTypeExtension
  end

end

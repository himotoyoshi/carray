# UNDEF as an operand, and object Integers cast to an integer type.
#
# - UNDEF as the scalar side of an operation with an array is a masked cell of
#   the array's own type: every cell of the result is masked, and the result
#   has the type the operation gives with any other scalar of that type.  An
#   integer, boolean or fixlen array used to answer an object array, while a
#   float array kept its type.
# - UNDEF asks the mask in a categorical's eq / ne / count, as it does in
#   CArray#eq and on the other Faces.
# - An object Integer cast with to_type keeps the C conversion (its low bytes),
#   whatever its size; one wider than 64 bits used to raise with Ruby's
#   internal "bignum too big to convert into `long'".

require 'test/unit'
require 'carray'

class TestUndefOperandAndObjectIntegerCast < Test::Unit::TestCase

  def masked_all?(c)
    c.has_mask? && c.count_masked == c.elements
  end

  def test_undef_operand_keeps_the_integer_type
    [CA_INT8([1, 2]), CA_UINT8([1, 2]), CA_INT32([1, 2]), CA_INT64([1, 2]),
     CA_FLOAT32([1, 2]), CA_FLOAT64([1, 2]), CA_CMPLX128([1, 2])].each do |a|
      [a + UNDEF, a * UNDEF, a - UNDEF, a / UNDEF,
       a.lazy + UNDEF].each do |r|
        r = r.copy
        assert_equal a.data_type, r.data_type, a.data_type_name
        assert masked_all?(r), a.data_type_name
      end
      next if a.complex?
      r = a.pmax(UNDEF)
      assert_equal a.data_type, r.data_type, a.data_type_name
      assert masked_all?(r), a.data_type_name
    end
  end

  def test_undef_operand_on_boolean_is_boolean_arithmetic
    b = CA_BOOLEAN([true, false])
    r = b + UNDEF
    assert_equal CA_INT64, r.data_type   # as b + b
    assert masked_all?(r)
  end

  def test_undef_operand_on_boolean_logic_is_kleene
    b = CA_BOOLEAN([true, false])
    assert_equal [UNDEF, false], (b & UNDEF).to_a
    assert_equal [true, UNDEF], (b | UNDEF).to_a
    assert_equal [UNDEF, UNDEF], (b ^ UNDEF).to_a
  end

  def test_undef_operand_in_a_bang_masks_every_cell
    a = CA_INT32([1, 2])
    a.add!(UNDEF)
    assert_equal CA_INT32, a.data_type
    assert masked_all?(a)
    b = CA_INT8([1, 2])
    b.mul!(UNDEF)
    assert masked_all?(b)
  end

  def test_undef_operand_on_fixlen_is_refused_as_other_operands
    f = CA_FIXLEN(%w[a b], bytes: 1)
    assert_raise(CArray::DataTypeError) { f + UNDEF }
    assert_raise(CArray::DataTypeError) { f + "a" }
  end

  def test_undef_operand_on_object_stays_object
    r = CA_OBJECT([1, 2]) + UNDEF
    assert_equal CA_OBJECT, r.data_type
    assert masked_all?(r)
  end

  def test_categorical_eq_undef_asks_the_mask
    c = CArray.string(["a", nil, "c"]).categorize
    assert_equal [false, true, false], c.eq(UNDEF).to_a
    assert_equal [true, false, true], c.ne(UNDEF).to_a
    assert !c.eq(UNDEF).has_mask?
    assert_equal 1, c.count(UNDEF)
    assert_equal c.count_masked, c.count(UNDEF)
    s = CArray.string(["a", nil, "c"])
    assert_equal s.eq(UNDEF).to_a, c.eq(UNDEF).to_a
    assert_equal s.count(UNDEF), c.count(UNDEF)
  end

  def test_categorical_eq_label_is_unchanged
    c = CArray.string(["a", nil, "c"]).categorize
    assert_equal [true, UNDEF, false], c.eq("a").to_a
    assert_equal 1, c.count("a")
    assert_equal 0, c.count("z")
  end

  def test_object_integer_to_type_keeps_the_low_bytes
    assert_equal [1, 44], CA_OBJECT([1, 300]).to_type(:int8).to_a
    assert_equal [1, 255], CA_OBJECT([1, -1]).to_type(:uint8).to_a
    assert_equal [1, 0], CA_OBJECT([1, 2**70]).to_type(:int32).to_a
    assert_equal [5], CA_OBJECT([2**70 + 5]).to_type(:uint8).to_a
    assert_equal [-2**63], CA_OBJECT([2**63]).to_type(:int64).to_a
    assert_equal [-1], CA_OBJECT([2**64 - 1]).to_type(:int64).to_a
    assert_equal [2**64 - 1], CA_OBJECT([-1]).to_type(:uint64).to_a
    assert_equal [5], CA_OBJECT([-(2**64) + 5]).to_type(:uint64).to_a
  end

  def test_object_integer_to_type_agrees_with_the_integer_cast
    o = CA_OBJECT([300, -1, 2**40 + 7])
    i = CA_INT64([300, -1, 2**40 + 7])
    %i[int8 uint8 int16 uint16 int32 uint32].each do |t|
      assert_equal i.to_type(t).to_a, o.to_type(t).to_a, t.to_s
    end
  end

  def test_object_integer_store_and_view_still_refuse
    assert_raise(RangeError) { CA_OBJECT([2**70]).as_type(:int32).copy }
    assert_raise(RangeError) { a = CArray.int32(1); a[] = CA_OBJECT([2**70]) }
    assert_raise(RangeError) { a = CArray.int8(1); a[] = CA_OBJECT([300]) }
  end

  def test_object_unreadable_cell_still_masks
    assert_equal [1, UNDEF], CA_OBJECT([1, nil]).to_type(:int32).to_a
    assert_equal [1, UNDEF], CA_OBJECT([1, "x"]).to_type(:int64).to_a
  end

  def test_a_wide_object_integer_is_refused_as_a_boolean_as_any_other
    [2**70, -2**64, 2**40, 2].each do |v|
      e = assert_raise(CArray::DataTypeError) { CA_OBJECT([v]).to_type(:boolean) }
      assert_match(/can't cast object '#{v}' to <boolean>/, e.message)
    end
    assert_equal [false, true], CA_OBJECT([0, 1]).to_type(:boolean).to_a
  end

  def test_object_number_past_an_integer_type_is_missing_as_a_float_cell_is
    require "bigdecimal"
    assert_equal [UNDEF], CA_OBJECT([1e30]).to_type(:int64).to_a
    assert_equal [UNDEF], CA_OBJECT([3.0e9]).to_type(:int32).to_a
    assert_equal [UNDEF], CA_OBJECT([Rational(2**70)]).to_type(:int32).to_a
    assert_equal [UNDEF], CA_OBJECT([BigDecimal("1e30")]).to_type(:int64).to_a
    assert_equal [UNDEF], CA_OBJECT([Complex(300, 0)]).to_type(:int8).to_a
    v = [127.9, -128.9, 128.0, 255.9, -0.9, 256.0, -1.0]
    %i[int8 uint8].each do |t|
      assert_equal CA_FLOAT64(v).to_type(t).to_a, CA_OBJECT(v).to_type(t).to_a, t.to_s
    end
    assert_equal [44], CA_OBJECT([300]).to_type(:int8).to_a
  end
end

# A scalar operand beside an integer array -- a Ruby Integer or an integer
# CScalar, which is taken at its value as an Integer is -- that the array's
# type can not hold:
#
#   - + - * & | ^: the answer modulo 2 ** bits, as C gives it
#   - pmin, pmax, minimum, maximum, clip, scatter_min!, scatter_max!,
#     elem_min, elem_max: one past the side where it can never be picked
#     gives the answer the type's bound gives, so it is taken at that
#     bound; one that would be picked in every cell is refused (RangeError)
#   - / % divmod fmod: cut to the type, the operand would give another
#     answer, so it is refused (RangeError)
#   - comparisons, count, search: answered by value
#   - **: the exponent is a count; a negative one on an unsigned array
#     too, as on a signed one.  A base on the left is cut to the type where
#     the exponent is 0 or more, and gives 0 where it is negative
#
# A store is not an operation: it writes a value of the cell's type, so an
# Integer (or integer CScalar) the type can not hold is refused, as a Float
# is.  A store from an integer array keeps the C conversion, as to_type does.

require "test/unit"
require "carray"

class TestScalarOperandRules < Test::Unit::TestCase

  def u8; CA_UINT8([0, 1, 2]); end
  def i8; CA_INT8([1, 2, 3]); end

  def int8 (v)
    r = v % 256
    return ( r > 127 ) ? r - 256 : r
  end

  def test_a_ring_operation_keeps_the_answer_modulo_the_type
    assert_equal [255, 0, 1], (u8 + 255).to_a
    assert_equal [0, 1, 2],   (u8 + 256).to_a
    assert_equal (u8 - 1).to_a, (u8 + -1).to_a
    assert_equal [-24, -48, -72], (i8 * 1000).to_a
    assert_equal [2, 3, 4], (i8 + (2**70 + 1)).to_a
    assert_equal [-25, -26, -27], (1000 - i8).to_a
    assert_equal [1, 2, 3], (i8 & 0x1ff).to_a
    assert_equal [0, 1, 2], (u8.lazy + 256).to_a
    a = i8
    a.add!(1000)
    assert_equal [-23, -22, -21], a.to_a
  end

  def test_the_left_hand_form_is_the_right_hand_form
    u = CA_UINT8([1, 2])
    assert_equal (u + 2**70).to_a, (2**70 + u).to_a
    assert_equal [255, 254], (2**70 - u).to_a
    assert_equal (u * 1000).to_a, (1000 * u).to_a
    assert_equal [1], ((-2**63 - 1) & CA_INT64([1])).to_a
    assert_equal [233, 234], (1000 + u.lazy).to_a
    c = CScalar.uint8 { 5 }
    assert_equal (c + 1000).to_a, (1000 + c).to_a
    assert_equal :uint8, (1000 + c).data_type
    assert_equal [(1000 - 5) % 256], (1000 - c).to_a
    assert_raise(RangeError) { 1000 / c }
  end

  def test_the_wrapped_answer_is_the_wide_answer_cut_to_the_type
    wide = CA_INT16([1, 2, 3])
    [:+, :-, :*, :&, :|, :^].each do |op|
      assert_equal (wide.send(op, 1000)).to_type(:int8).to_a, i8.send(op, 1000).to_a, op.to_s
    end
  end

  def test_a_division_refuses
    assert_raise(RangeError) { i8 / 1000 }
    assert_raise(RangeError) { i8 % 1000 }
    assert_raise(RangeError) { 1000 / i8 }
    assert_raise(RangeError) { i8.lazy / 1000 }
    assert_raise(RangeError) { i8.div!(1000) }
    assert_raise(RangeError) { i8.fmod(1000) }
    assert_raise(RangeError) { i8.divmod(1000) }
  end

  def test_a_bound_that_can_never_be_picked_leaves_the_cells
    s = CA_INT8([-3, 0, 5])
    assert_equal [-3, 0, 5], s.pmin(1000).to_a
    assert_equal [-3, 0, 5], s.pmax(-1000).to_a
    assert_equal [-3, 0, 5], s.minimum(2**70).to_a
    assert_equal [-3, 0, 5], s.maximum(-2**70).to_a
    assert_equal [-3, 0, 5], s.pmin(CA_INT64([1000, 1, 1000])).to_a
    assert_equal [-3, 0, 1], s.pmin(CA_INT64([1000, 1000, 1])).to_a
    assert_equal [-3, 0, 5], s.lazy.pmin(1000).to_a
    assert_equal [-3, 0, 5], s.copy.tap { |x| x.pmin!(1000) }.to_a
    assert_equal [0, 0, 5],  s.clip(0, 1000).to_a
    assert_equal [-3, 0, 4], s.clip(-1000, 4).to_a
    assert_equal [0, 0, 5],  s.lazy.clip(0, 1000).to_a
    assert_equal [0, 5],     CA_UINT8([0, 5]).pmax(-1).to_a
    assert_equal [1, 2],     i8.scatter_min!([0], 1000).to_a[0, 2]
    assert_equal [1, 7, 3],  i8.scatter_max!([0, 1], [-1000, 7]).to_a
    assert_equal [1, 2, 3],  i8.elem_min(0, 1000).to_a
    assert_equal [1, 2, 3],  i8.elem_max(0, -1000).to_a
  end

  def test_a_bound_that_would_be_picked_in_every_cell_refuses
    assert_raise(RangeError) { i8.pmax(1000) }
    assert_raise(RangeError) { i8.pmin(-1000) }
    assert_raise(RangeError) { i8.lazy.pmin(-1000) }
    assert_raise(RangeError) { i8.clip(200, 1000) }
    assert_raise(RangeError) { i8.clip(-1000, -1000) }
    assert_raise(RangeError) { CA_UINT8([0, 5]).pmin(-1) }
    a = i8
    assert_raise(RangeError) { a.scatter_max!([0], 1000) }
    assert_raise(RangeError) { a.scatter_min!([0], [-1000]) }
    assert_raise(RangeError) { a.scatter_max!([0], CScalar.int64 { 300 }) }
    assert_raise(RangeError) { a.elem_max(0, 1000) }
    assert_raise(RangeError) { a.elem_min(0, -1000) }
    assert_equal [1, 2, 3], a.to_a
  end

  def test_an_operation_the_type_does_not_define_says_so_first
    [:and, :and!, :or!, :xor, :atan2, :atan2!, :copysign, :quo_i!].each do |m|
      [3, 1000, CA_INT64(1000)].each do |v|
        assert_raise(CArray::DataTypeError, "#{m}(#{v.inspect})") { i8.send(m, v) }
      end
    end
    assert_raise(CArray::DataTypeError) { CA_INT64(1000).atan2(i8) }
  end

  def test_a_comparison_answers_by_value
    assert_equal [true, true, true],    (u8 < 1000).to_a
    assert_equal [true, true, true],    (u8 > -1000).to_a
    assert_equal [false, false, false], u8.eq(256).to_a
  end

  def test_a_cscalar_is_taken_at_its_value
    big = CA_INT64(1000)
    assert_equal (i8 + 1000).to_a, (i8 + big).to_a
    assert_raise(RangeError) { i8 / big }
    assert_raise(RangeError) { i8.pmax(big) }
    assert_equal [1, 2, 3], i8.clip(0, big).to_a
    assert_equal [true, true, true],    (u8 < big).to_a
    assert_equal [false, false, false], u8.eq(CA_INT64(256)).to_a
    assert_equal [true, true, true],    (u8 > CA_INT64(-1)).to_a
    assert_equal [true, true, true],    (u8.lazy > CA_INT64(-1)).to_a
    assert_equal (i8 ** 1000).to_a,     (i8 ** big).to_a
    assert_equal :int8, (i8 + CA_INT64(100)).data_type
  end

  def test_the_exponent_is_a_count
    assert_equal [0, 169], (CA_UINT8([2, 3]) ** 10).to_a
    assert_equal [1, 0, int8(3**1000)], (i8 ** 1000).to_a
    assert_equal (i8 ** 1000).to_a, (i8.lazy ** 1000).to_a
    assert_equal (i8 ** 1000).to_a, i8.pow(1000).to_a
    assert_equal (i8 ** 1000).to_a, i8.tap { |a| a.pow!(1000) }.to_a
    assert_equal [1, 1, 0],  (CA_INT8([1, -1, 2]) ** -1000).to_a
    assert_equal [1, -1, 0], (CA_INT8([1, -1, 2]) ** -1001).to_a
    [8, 9, 70, 71, 1000, 2**70].each do |p|
      [2, 3, -3, 5].each do |x|
        assert_equal int8(x.pow(p, 256)), (CA_INT8([x]) ** p)[0], "#{x} ** #{p}"
      end
    end
  end

  def test_power_is_the_same_as_the_operator
    assert_equal (i8 ** 1000).to_a, i8.power(1000).to_a
    assert_equal (i8 ** 1000).to_a, i8.tap { |a| a.power!(1000) }.to_a
    assert_equal [1, 0], CA_UINT8([1, 2]).tap { |a| a.power!(-1) }.to_a
    assert_equal [33], CA_INT8([3]).power(CA_INT64(1000)).to_a
    assert_kind_of CABinOp, CA_INT8([2]).lazy.power(3)
  end

  def test_a_shift_bang_takes_the_count_as_the_operator_does
    [[CA_INT8([1, -8]), 1000], [CA_INT8([1, -8]), -1000], [CA_INT8([4, -8]), -1],
     [CA_UINT8([4, 200]), -1], [CA_UINT8([4, 200]), 300]].each do |a, n|
      assert_equal (a << n).to_a, a.copy.tap { |x| x.bit_lshift!(n) }.to_a, "<< #{n}"
      assert_equal (a >> n).to_a, a.copy.tap { |x| x.bit_rshift!(n) }.to_a, ">> #{n}"
    end
  end

  def test_an_unsigned_array_takes_a_negative_exponent
    assert_equal [1, 0, 0], (CA_UINT8([1, 2, 3]) ** -1).to_a
    assert_equal [1, 0], (CA_UINT64([1, 5]) ** -2**70).to_a
    assert_equal [1, 0], (CA_UINT8([1, 2]) ** CA_INT64(-3)).to_a
    assert_equal [1, 0], (CA_UINT8([1, 2]).lazy ** -1).to_a
    assert_equal [1, 0], CA_UINT8([1, 2]).tap { |a| a.pow!(-1) }.to_a
    assert_equal :uint8, (CA_UINT8([1]) ** -1).data_type
    assert_raise(ZeroDivisionError) { CA_UINT8([0, 1]) ** -1 }
    m = CA_UINT8([0, 1, 2])
    m[0] = UNDEF
    assert_equal [UNDEF, 1, 0], (m ** -1).to_a
  end

  def test_a_wide_unsigned_exponent_is_a_count
    xs = [0, 1, 3, 5]
    [2**63 - 1, 2**63, 2**64 - 1, 2**64, 2**70].each do |p|
      assert_equal xs.map { |x| x.pow(p, 2**64) }, (CA_UINT64(xs) ** p).to_a, p.to_s
    end
  assert_equal [3.pow(2**63, 2**64)], (CA_UINT64([3]) ** CScalar.uint64 { 2**63 }).to_a
  assert_equal [3, 5].map { |x| x.pow(2**32 - 1, 2**32) }, (CA_UINT32([3, 5]) ** (2**32 - 1)).to_a
end

  def test_an_unfit_base_on_the_left_is_the_wide_power_cut_to_the_type
    ps = [2, 3, 0, -1, -2, 7]
    [[1000, :int8], [-1000, :int8], [256, :int16], [2**70 + 3, :int64],
     [257, :int32]].each do |b, type|
      # b ** p computed exactly, then cut to 64 bits and to the type
      exact = ps.map { |p| ( p < 0 ) ? 0 : b.pow(p, 2**64) }
      wide = CA_INT64(exact.map { |v| ( v >= 2**63 ) ? v - 2**64 : v })
      a = CArray.new(type, [ps.size]) { ps }
      assert_equal wide.to_type(type).to_a, (b ** a).to_a, "#{b} ** #{type}"
      assert_equal type, (b ** a).data_type
    end
    [[256, :uint8], [257, :uint8], [1000, :uint16], [2**64 + 3, :uint64]].each do |b, type|
      a = CArray.new(type, [3]) { [2, 0, 1] }
      assert_equal [2, 0, 1].map { |p| b.pow(p, 2**(a.bytes * 8)) }, (b ** a).to_a, "#{b} ** #{type}"
    end
  end

  def test_an_unfit_base_on_the_left_in_other_forms
    assert_equal [64, 0, 1, 0], (CA_INT64(1000) ** CA_INT8([2, 3, 0, -1])).to_a
    assert_equal :int8, (CA_INT64(1000) ** CA_INT8([2])).data_type
    assert_equal [64, 0], (1000 ** CA_INT8([2, -1]).lazy).to_a
    m = CA_INT8([2, -1, 3])
    m[0] = UNDEF
    assert_equal [UNDEF, 0, 0], (1000 ** m).to_a
    assert_raise(RangeError) { 1000 / CA_INT8([1]) }
  end

  def test_a_store_refuses_a_value_the_type_can_not_hold
    assert_raise(RangeError) { i8[0] = 1000 }
    assert_raise(RangeError) { i8[0] = 1000.0 }
    assert_raise(RangeError) { CA_INT8([1000]) }
    assert_raise(RangeError) { i8.fill(300) }
    assert_raise(RangeError) { i8[] = CA_INT64(1000) }
    assert_raise(RangeError) { i8[] = CA_OBJECT([1000, 0, 0]) }
    a = i8
    assert_raise(RangeError) { a[] = [1, 1000, 1] }
    assert_equal [1, 2, 3], a.to_a
    assert_equal [1, 2, 3], i8.tap { |x| x[0] = 1.7 }.to_a
  end

  def test_a_store_from_an_integer_array_keeps_the_c_conversion
    assert_equal [-24, -24, -24], i8.tap { |x| x[] = CA_INT16([1000, 1000, 1000]) }.to_a
  end

end

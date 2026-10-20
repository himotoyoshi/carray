require "test/unit"
require "carray"

# A float with no integer of the target type -- NaN, an infinity, or a value
# out of range -- has no defined C conversion: x86 gives the type's minimum
# and ARM saturates.  CArray answers the same on both: to_type masks the
# cell, a store refuses it, and clip_<type> saturates.
class TestFloatToIntegerRange < Test::Unit::TestCase

  INF = Float::INFINITY

  def test_to_type_masks_a_cell_the_type_cannot_hold
    a = CA_DOUBLE([INF, -INF, 1e30, 2**63, -129, -128.5, 127.9, 1])
    assert_equal [UNDEF, UNDEF, UNDEF, UNDEF, UNDEF, -128, 127, 1], a.int8.to_a
    assert_equal [UNDEF, UNDEF, UNDEF, UNDEF, -129, -128, 127, 1], a.int64.to_a
    assert_equal [UNDEF, UNDEF, UNDEF, UNDEF, UNDEF, UNDEF, 127, 1], a.uint32.to_a
    assert_equal [-2**63], CA_DOUBLE([-2**63]).int64.to_a
    assert_equal [UNDEF, 0], CA_FLOAT([3e9, -0.5]).uint8.to_a
    assert_equal [UNDEF], CA_FLOAT([3e9]).int32.to_a
  end

  def test_a_store_refuses_a_cell_the_type_cannot_hold
    x = CArray.int32(2).fill(9)
    assert_raise(RangeError) { x[] = CA_DOUBLE([1, 1e30]) }
    assert_raise(FloatDomainError) { x[] = CA_DOUBLE([1, INF]) }
    assert_raise(FloatDomainError) { x[] = CA_DOUBLE([1, Float::NAN]) }
    assert_equal [9, 9], x.to_a, "nothing is written before the refusal"
    assert_raise(RangeError) { CA_DOUBLE([2**63]).as_int64.to_a }
  end

  def test_clip_saturates_a_float_source
    big = [1e30, -1e30, INF, -INF, 5.5]
    assert_equal [2**63 - 1, -2**63, 2**63 - 1, -2**63, 5], CA_DOUBLE(big).clip_int64.to_a
    assert_equal [2**31 - 1, -2**31, 2**31 - 1, -2**31, 5], CA_FLOAT(big).clip_int32.to_a
    assert_equal [2**32 - 1, 0, 2**32 - 1, 0, 5], CA_FLOAT(big).clip_uint32.to_a
    assert_equal [2**64 - 1, 0, 2**64 - 1, 0, 5], CA_DOUBLE(big).clip_uint64.to_a
    assert_equal [127, -128, 127, -128, 5], CA_DOUBLE(big).clip_int8.to_a
    assert_raise(FloatDomainError) { CA_DOUBLE([Float::NAN]).clip_int16 }
  end

  def test_a_time_mean_past_the_int64_range_is_masked
    t = CArray.int64(2, 1) { 2**63 - 1 }.timedelta(unit: :ns)
    assert_equal [UNDEF], t.mean(axis: 0).to_a
  end

  def test_integer_linspace_refuses_a_span_the_type_cannot_hold
    assert_raise(RangeError) { CArray::Int32.linspace(0, 1e30, 3) }
    assert_raise(RangeError) { CArray::UInt8.linspace(0, 1000, 3) }
    assert_equal [0, 127, 255], CArray::UInt8.linspace(0, 255, 3).to_a
  end

end

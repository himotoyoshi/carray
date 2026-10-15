# frozen_string_literal: true
#
# A store that cannot convert a cell names the method, as the other refusals
# do.  The refusals of the cast kernels -- a NaN into an integer cell, a
# number other than 0 or 1 into a boolean one -- are written by the
# generator (ext/carray_cast_func.rb), one template each, and said what was
# wrong but not where.

require "test/unit"
require "carray"

class TestCastRefusalNames < Test::Unit::TestCase

  def test_a_nan_into_an_integer_cell
    %i[int8 int32 uint64].each do |t|
      a = CArray.new(t, [2])
      e = assert_raise(FloatDomainError, t.to_s) { a[] = CA_DOUBLE([Float::NAN, 1.0]) }
      assert_equal "[]=: NaN cannot be converted to #{t}", e.message
    end
    e = assert_raise(FloatDomainError) { CArray.int32(1)[] = CA_DCOMPLEX([Complex(Float::NAN, 0)]) }
    assert_equal "[]=: NaN cannot be converted to int32", e.message
  end

  def test_a_number_other_than_0_or_1_into_a_boolean_cell
    e = assert_raise(RangeError) { CA_BOOLEAN([1, 0])[] = CA_INT32([2, 0]) }
    assert_equal "[]=: out of range to cast to boolean (0 or 1)", e.message
  end

  # #to_type takes a NaN to UNDEF, so it has nothing to refuse.
  def test_to_type_still_masks_a_nan
    assert_equal [1, UNDEF], CA_DOUBLE([1.0, Float::NAN]).to_type(:int32).to_a
  end

end

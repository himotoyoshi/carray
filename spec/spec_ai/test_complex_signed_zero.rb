# Signed zeros survive a store into a complex CArray.
#
# rb_carray_num2cmplx used to build the value as `re + I * im`.  That
# evaluates `I * im` first, so an imaginary part of +0.0 produced
# (0.0 + 0.0i), and adding it to a real part of -0.0 gave +0.0 -- the sign
# of the negative zero real part was lost.  Only the (-0.0, +0.0) corner
# was affected, which is why the other three sign combinations looked fine.
#
# The sign of a zero selects the side of a branch cut (log(-1+0i) = +pi*i,
# log(-1-0i) = -pi*i), so a value that changes sign on its way into an
# array can send a later computation to the wrong branch.

require 'test/unit'
require 'carray'

class TestComplexSignedZero < Test::Unit::TestCase

  SIGNS = [0.0, -0.0]

  def sign_of(x)
    # 1.0 / -0.0 is -Infinity, 1.0 / 0.0 is +Infinity
    (1.0 / x) < 0 ? -1 : 1
  end

  def assert_zero_signs(expected, actual, message)
    assert_equal([sign_of(expected.real), sign_of(expected.imag)],
                 [sign_of(actual.real),   sign_of(actual.imag)],
                 message)
  end

  def check_round_trip (data_type)
    SIGNS.each do |re|
      SIGNS.each do |im|
        z = Complex(re, im)
        a = CArray.new(data_type, [1])
        a[0] = z
        assert_zero_signs(z, a[0], "#{data_type} round trip of #{z.inspect}")
      end
    end
  end

  def test_cmplx128_round_trip
    check_round_trip(CA_CMPLX128)
  end

  def test_cmplx64_round_trip
    check_round_trip(CA_CMPLX64)
  end

  def test_negative_zero_real_with_positive_zero_imag
    # The single case that regressed.
    r = CArray.cmplx128(1)
    r[0] = Complex(-0.0, 0.0)
    assert_equal(-1, sign_of(r[0].real))
    assert_equal( 1, sign_of(r[0].imag))
  end

  def test_bulk_cast_preserves_signed_zeros
    # The same conversion is used by the object -> complex cast table.
    src = CA_OBJECT([Complex(-0.0, 0.0), Complex(0.0, -0.0),
                     Complex(-0.0, -0.0), Complex(0.0, 0.0)])
    [CA_CMPLX64, CA_CMPLX128].each do |data_type|
      dst = src.to_type(data_type)
      4.times do |i|
        assert_zero_signs(src[i], dst[i],
                          "#{data_type} cast of #{src[i].inspect}")
      end
    end
  end

  def test_branch_cut_side_is_preserved
    # log(-1 + 0i) = +pi*i, log(-1 - 0i) = -pi*i.  Storing the operand in a
    # CArray must not move it across the cut.
    a = CArray.cmplx128(2)
    a[0] = Complex(-1.0,  0.0)
    a[1] = Complex(-1.0, -0.0)
    log = a.log
    assert_operator(log[0].imag, :>, 0)
    assert_operator(log[1].imag, :<, 0)
  end

end

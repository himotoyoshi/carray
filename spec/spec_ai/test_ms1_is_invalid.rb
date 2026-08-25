# MS.1: rb_ca_is_invalid -- NaN/Inf predicate.
#
# PROPOSAL_MASK_SET_FAMILY.md §2.5 confirmed: is_invalid follows school
# A (= mask propagate), equivalent to is_finite.not.  This test pins:
#   - boolean output, same shape as self
#   - NaN/Inf -> true, finite real -> false (float data_type)
#   - integer/bool data_type -> all false (no NaN/Inf concept)
#   - mask propagation (= masked cell -> UNDEF, school A)
#   - byte parity with is_finite.not on unmasked cells
#   - complex data_type: invalid if either real or imag is NaN/Inf

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestMS1IsInvalid < Test::Unit::TestCase

  # ---- bool output + shape ---------------------------------------------

  def test_returns_boolean_array
    a = CArray.float64(5).seq
    r = a.is_invalid
    assert_kind_of(CArray, r)
    assert_equal(:boolean, r.data_type_name.to_sym)
    assert_equal(a.shape, r.shape)
  end

  # ---- float data_type: NaN / Inf / finite ---------------------------------

  def test_float_nan_inf_finite
    a = CArray.float64(6)
    a[0] = 0.0
    a[1] = 1.5
    a[2] = 0.0 / 0.0     # NaN
    a[3] = 1.0 / 0.0     # +Inf
    a[4] = -1.0 / 0.0    # -Inf
    a[5] = -3.14
    assert_equal([false, false, true, true, true, false], a.is_invalid.to_a)
  end

  def test_float32_nan_inf_finite
    a = CArray.float32(4)
    a[0] = 1.0
    a[1] = (0.0 / 0.0).to_f
    a[2] = (1.0 / 0.0).to_f
    a[3] = -2.0
    assert_equal([false, true, true, false], a.is_invalid.to_a)
  end

  # ---- school A: mask propagate ----------------------------------------

  def test_mask_propagate_masked_to_undef
    a = CArray.float64(5).seq
    a[2] = UNDEF
    r = a.is_invalid
    assert(r.has_mask?, "is_invalid should propagate mask (school A)")
    assert_equal(true, r.is_masked[2])
    assert_equal(false, r.is_masked[0])
  end

  def test_no_mask_when_input_unmasked
    a = CArray.float64(5).seq
    refute(a.is_invalid.has_mask?,
           "no mask should be created when input is unmasked")
  end

  # ---- byte parity with is_finite.not ----------------------------------

  def test_parity_with_is_finite_not_unmasked
    a = CArray.float64(8)
    a[0] = 0.0; a[1] = 1.5
    a[2] = 0.0 / 0.0
    a[3] = 1.0 / 0.0
    a[4] = -1.0 / 0.0
    a[5] = -3.14; a[6] = 1e308; a[7] = -1e308
    assert_equal(a.is_finite.not.to_a, a.is_invalid.to_a)
  end

  def test_parity_with_is_finite_not_with_mask
    a = CArray.float64(6)
    a[0] = 1.0; a[1] = 0.0 / 0.0; a[2] = 1.0 / 0.0
    a[3] = -1.0 / 0.0; a[4] = 2.0; a[5] = 3.0
    a[3] = UNDEF
    fn = a.is_finite.not
    ii = a.is_invalid
    # Both should have mask at the same positions
    assert_equal(fn.is_masked.to_a, ii.is_masked.to_a)
    # Unmasked values match
    a.elements.times do |i|
      next if ii.is_masked[i]
      assert_equal(fn[i], ii[i], "cell #{i} parity mismatch")
    end
  end

  # ---- integer + bool: all false ---------------------------------------

  def test_integer_data_type_all_false
    [:int8, :int16, :int32, :int64,
     :uint8, :uint16, :uint32, :uint64].each do |t|
      a = CArray.send(t, 5).seq
      r = a.is_invalid
      assert_equal([false, false, false, false, false], r.to_a,
                   "data_type #{t} should be all false (no NaN/Inf)")
    end
  end

  def test_boolean_data_type_all_false
    a = CArray.int32(4).seq.ne(0)
    assert_equal([false, false, false, false], a.is_invalid.to_a)
  end

  def test_integer_with_mask_propagates
    a = CArray.int32(5).seq
    a[2] = UNDEF
    r = a.is_invalid
    assert(r.has_mask?)
    assert_equal(true, r.is_masked[2])
    # All unmasked values are 0 (integer has no NaN/Inf)
    assert_equal(false, r[0])
    assert_equal(false, r[4])
  end

  # ---- complex data_type ---------------------------------------------------

  def test_complex_real_nan
    a = CArray.cmplx128(3)
    a[0] = Complex(1.0, 2.0)
    a[1] = Complex(0.0 / 0.0, 1.0)   # real NaN
    a[2] = Complex(3.0, 1.0 / 0.0)   # imag Inf
    r = a.is_invalid
    assert_equal([false, true, true], r.to_a)
  end

  # ---- consistency with mask_invalid use case --------------------------

  def test_indexer_assign_undef_via_chain
    # ca[a.is_invalid] = UNDEF should mask exactly the NaN/Inf cells.
    # (This is what the future ca[:is_invalid] = UNDEF indexer key will
    # dispatch to internally.)
    a = CArray.float64(5)
    a[0] = 1.0; a[1] = 0.0 / 0.0; a[2] = 2.0
    a[3] = 1.0 / 0.0; a[4] = 3.0
    a[a.is_invalid] = UNDEF
    assert_equal([false, true, false, true, false], a.is_masked.to_a)
    # finite values preserved
    assert_equal(1.0, a[0])
    assert_equal(2.0, a[2])
    assert_equal(3.0, a[4])
  end

  # ---- response surface ------------------------------------------------

  def test_is_invalid_is_zero_arity
    a = CArray.float64(3).seq
    assert_equal(0, a.method(:is_invalid).arity)
    assert_raise(ArgumentError) { a.is_invalid(0) }
  end
end

# MS.5: mask_invalid -- return-form sugar for masking NaN/Inf cells.
#
# PROPOSAL_MASK_SET_FAMILY.md §2.2: zero-arity sugar (predicate fixed),
# equivalent to ca.dup.tap { |c| c[:is_invalid] = UNDEF }.  For integer
# / boolean data_types the result is a plain copy with no mask (because no
# cell can be NaN/Inf).

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestMS5MaskInvalid < Test::Unit::TestCase

  def test_returns_new_array
    a = CArray.float64(5).seq
    b = a.mask_invalid
    refute_equal(a.object_id, b.object_id)
  end

  def test_self_unchanged
    a = CArray.float64(5)
    a[0] = 1.0; a[1] = 0.0 / 0.0; a[2] = 2.0
    a[3] = 1.0 / 0.0; a[4] = 3.0
    a.mask_invalid
    refute(a.has_mask?, "self should not gain mask")
  end

  def test_nan_inf_masked
    a = CArray.float64(7)
    a[0] = 0.0; a[1] = 1.0; a[2] = 0.0 / 0.0
    a[3] = 1.0 / 0.0; a[4] = -1.0 / 0.0
    a[5] = 5.0; a[6] = 6.0
    b = a.mask_invalid
    assert_equal([false, false, true, true, true, false, false], b.is_masked.to_a)
  end

  def test_finite_values_preserved
    a = CArray.float64(5).seq
    a[2] = 0.0 / 0.0
    b = a.mask_invalid
    assert_equal(0.0, b[0])
    assert_equal(1.0, b[1])
    assert_equal(3.0, b[3])
    assert_equal(4.0, b[4])
  end

  def test_no_nan_inf_no_mask
    a = CArray.float64(5).seq
    b = a.mask_invalid
    refute(b.has_mask?, "no NaN/Inf input -> no mask in output")
  end

  # ---- integer / boolean: no-op copy -----------------------------------

  def test_integer_data_type_is_noop
    [:int8, :int16, :int32, :int64,
     :uint8, :uint16, :uint32, :uint64].each do |t|
      a = CArray.send(t, 5).seq
      b = a.mask_invalid
      refute(b.has_mask?, "data_type #{t}: no NaN/Inf possible")
      assert_equal(a.to_a, b.to_a)
    end
  end

  def test_boolean_data_type_is_noop
    a = CArray.int32(4).seq.ne(0)
    b = a.mask_invalid
    refute(b.has_mask?)
  end

  # ---- consistency with indexer + chain --------------------------------

  def test_consistency_with_indexer_idiom
    a = CArray.float64(6)
    a[0] = 1.0; a[1] = 0.0 / 0.0
    a[2] = 2.0; a[3] = 1.0 / 0.0
    a[4] = -1.0 / 0.0; a[5] = 3.0
    x = a.mask_invalid
    y = a.dup
    y[:is_invalid] = UNDEF
    assert_equal(y.is_masked.to_a, x.is_masked.to_a)
  end

  def test_preserves_existing_mask
    a = CArray.float64(5)
    a[0] = 1.0; a[1] = 0.0 / 0.0
    a[2] = 2.0; a[3] = UNDEF
    a[4] = 1.0 / 0.0
    b = a.mask_invalid
    # cell 1 NaN, 3 pre-mask, 4 Inf -- all 3 masked
    assert_equal([false, true, false, true, true], b.is_masked.to_a)
  end

  # ---- arity strict ----------------------------------------------------

  def test_one_arg_raises
    a = CArray.float64(3).seq
    assert_raise(ArgumentError) { a.mask_invalid(0) }
  end

  # ---- chain ergonomics ------------------------------------------------

  def test_chain_with_sum
    a = CArray.float64(5)
    a[0] = 1.0; a[1] = 0.0 / 0.0
    a[2] = 2.0; a[3] = 1.0 / 0.0
    a[4] = 3.0
    # mask_invalid masks NaN+Inf, sum of remaining = 1+2+3 = 6
    assert_equal(6.0, a.mask_invalid.sum)
  end
end

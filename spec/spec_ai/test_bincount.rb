# PROPOSAL_AT_FAMILY G.3: bincount tests.

require 'test/unit'
require 'carray'

class TestBincount < Test::Unit::TestCase

  # ---- basic counting ----

  def test_bincount_basic_returns_uint32
    # PROPOSAL_BINCOUNT_DEDICATED_KERNEL: 3.0 breaking — output dtype
    # is UInt32 (length < 2^32) or UInt64, matching numpy/numo convention.
    labels = CA_INT64([0, 1, 1, 2, 0, 1])
    r = labels.bincount
    assert_equal(CA_UINT32, r.data_type)
    assert_equal([2, 3, 1], r.to_a)
  end

  def test_bincount_with_length_kwarg_pads_with_zeros
    labels = CA_INT64([0, 1, 1, 2, 0, 1])
    assert_equal([2, 3, 1, 0, 0], labels.bincount(length: 5).to_a)
  end

  def test_bincount_length_smaller_than_max_uses_max
    labels = CA_INT64([0, 5])
    assert_equal([1, 0, 0, 0, 0, 1], labels.bincount(length: 2).to_a)
  end

  # ---- weighted bincount ----

  def test_bincount_weighted_inherits_weights_dtype
    labels  = CA_INT64([0, 1, 1, 2, 0, 1])
    weights = CA_DOUBLE([1, 2, 3, 4, 5, 6])
    r = labels.bincount(weights: weights)
    assert_equal(CA_FLOAT64, r.data_type)
    assert_equal([6.0, 11.0, 4.0], r.to_a)
  end

  def test_bincount_weighted_int32_weights
    labels  = CA_INT64([0, 0, 1])
    weights = CA_INT32([3, 4, 5])
    r = labels.bincount(weights: weights)
    assert_equal(CA_INT32, r.data_type)
    assert_equal([7, 5], r.to_a)
  end

  # ---- mask handling ----

  def test_bincount_masked_labels_skipped
    labels = CA_INT64([0, 1, 1, 2, 0, 1])
    labels[2] = UNDEF
    assert_equal([2, 2, 1], labels.bincount.to_a)
  end

  def test_bincount_all_masked_returns_zeros
    # Every cell masked (non-empty input): no labels to count. Must not crash
    # on minmax => UNDEF; behaves like empty input.
    labels = CA_INT64([1, 2, 3])
    labels[] = UNDEF
    assert_equal([], labels.bincount.to_a)
    assert_equal([0, 0, 0, 0], labels.bincount(length: 4).to_a)
  end

  def test_bincount_weighted_masked_weights_contribute_zero
    labels  = CA_INT64([0, 1, 1])
    weights = CA_DOUBLE([1, 2, 3])
    weights[1] = UNDEF
    # idx 1 masked weight → skipped; labels[1]=1 contributes nothing
    r = labels.bincount(weights: weights)
    assert_equal([1.0, 3.0], r.to_a)
  end

  # ---- empty input ----

  def test_bincount_empty_default_length_returns_empty
    r = CA_INT64([]).bincount
    assert_equal(CA_UINT32, r.data_type)
    assert_equal([], r.to_a)
  end

  def test_bincount_empty_with_length_returns_zeros
    assert_equal([0, 0, 0], CA_INT64([]).bincount(length: 3).to_a)
  end

  # ---- input validation ----

  def test_bincount_negative_label_raises
    assert_raise(ArgumentError) {
      CA_INT64([0, -1, 1]).bincount
    }
  end

  def test_bincount_float_dtype_raises
    assert_raise(CArray::DataTypeError) {
      CA_DOUBLE([0, 1, 1]).bincount
    }
  end

  def test_bincount_boolean_dtype_raises
    assert_raise(CArray::DataTypeError) {
      CArray.boolean(3) { 0 }.bincount
    }
  end

  # ---- integer dtype variants ----

  def test_bincount_int8_labels
    labels = CA_INT64([0, 1, 1, 2, 0]).int8
    assert_equal(CA_INT8, labels.data_type)
    assert_equal([2, 2, 1], labels.bincount.to_a)
  end

  def test_bincount_uint16_labels
    labels = CA_INT64([3, 1, 1, 0]).uint16
    assert_equal([1, 2, 0, 1], labels.bincount.to_a)
  end

  # ---- duplicate label accumulation (= via scatter_add! unbuffered) ----

  def test_bincount_all_same_label
    labels = CA_INT64([2, 2, 2, 2, 2])
    assert_equal([0, 0, 5], labels.bincount.to_a)
  end

end

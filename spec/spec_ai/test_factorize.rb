# Test for CArray#factorize, the public surface over the one-pass value hash
# (C __factorize_appearance__, pinned in test_factorize_appearance.rb).
#
# Contract of this surface, as distinct from the kernel's:
#   - answers [codes, levels]; levels is what #unique answers, in the same
#     first-appearance order, and codes indexes it: levels[codes[i]] == self[i].
#   - codes keeps self's shape; levels is always 1-D.
#   - a masked cell is excluded, and its code is BOTH masked and the sentinel,
#     which is what CACategorical's storage is. The kernel writes the sentinel
#     and leaves the mask off, so the mask is this method's own doing.
#   - no sort:, because the codes index the levels.

require "test/unit"
require "carray"

class TestFactorize < Test::Unit::TestCase

  def assert_round_trip (a, msg)
    codes, levels = a.factorize
    assert_equal a.shape, codes.shape, "#{msg}: codes keep the shape"
    assert_equal 1, levels.ndim, "#{msg}: levels are flat"
    assert_equal a.unique.to_a, levels.to_a, "#{msg}: levels are #unique"
    a.elements.times do |i|
      next if a.is_masked[i]
      assert_equal a[i], levels[codes[i]], "#{msg}: cell #{i} decodes"
    end
  end

  def test_appearance_order
    a = CA_INT32([5, 3, 5, 7, 3, 1])
    codes, levels = a.factorize
    assert_equal [5, 3, 7, 1], levels.to_a
    assert_equal [0, 1, 0, 2, 1, 3], codes.to_a
  end

  def test_round_trip_integer
    assert_round_trip(CA_INT32([3, 1, 3, 7, 1, 3, 7, 1]), "int32")
  end

  def test_round_trip_negative
    assert_round_trip(CA_INT32([-5, 2, -5, 0, 2, -5]), "negatives")
  end

  def test_round_trip_float
    assert_round_trip(CA_FLOAT64([1.5, 2.5, 1.5, 0.25, 2.5]), "float64")
  end

  def test_round_trip_object
    assert_round_trip(CArray.object(4) { |i| ["a", "b", "a", "c"][i] }, "object")
  end

  def test_round_trip_boolean
    assert_round_trip(CArray.boolean(5) { |i| i.even? }, "boolean")
  end

  def test_codes_keep_the_shape
    a = CArray.int64(3, 4) { |i, j| (i * 4 + j) % 5 }
    codes, levels = a.factorize
    assert_equal [3, 4], codes.shape
    assert_equal [5], levels.shape
    assert_round_trip(a, "multi_dim")
  end

  def test_levels_agree_with_unique
    a = CA_FLOAT64([2.0, 9.0, 2.0, 4.0, 9.0])
    _, levels = a.factorize
    assert_equal a.unique.to_a, levels.to_a
    assert_equal a.unique.data_type, levels.data_type
  end

  def test_masked_cell_is_masked_and_sentinel
    a = CA_INT32([3, 1, 3, 7, 1, 3])
    a[1] = UNDEF
    a[4] = UNDEF
    codes, levels = a.factorize
    assert_equal a.is_masked.to_a, codes.is_masked.to_a
    assert_equal [3, 7], levels.to_a
    sentinel = CACategorical::SENTINEL[codes.data_type]
    assert_equal sentinel, codes.value[1]
    assert_equal sentinel, codes.value[4]
  end

  def test_masked_cells_never_reach_the_levels
    a = CA_INT32([5, 9, 5])
    a[1] = UNDEF
    _, levels = a.factorize
    assert_equal [5], levels.to_a
    assert_equal 0, levels.count_masked
  end

  def test_all_masked
    a = CA_FLOAT64([1.0, 2.0])
    a.mask = [1, 1]
    codes, levels = a.factorize
    assert_equal 0, levels.elements
    assert_equal 2, codes.count_masked
  end

  def test_empty
    codes, levels = CArray.int64(0).factorize
    assert_equal 0, levels.elements
    assert_equal 0, codes.elements
  end

  def test_single_value
    codes, levels = CA_INT32([7, 7, 7, 7]).factorize
    assert_equal [7], levels.to_a
    assert_equal [0, 0, 0, 0], codes.to_a
  end

  def test_code_data_type_narrows_and_widens
    assert_equal CA_UINT8,  CArray.int32(300) { |i| i % 200 }.factorize.first.data_type
    assert_equal CA_UINT16, CArray.int32(1000) { |i| i % 300 }.factorize.first.data_type
    assert_equal CA_UINT32, CArray.int32(100000) { |i| i % 70000 }.factorize.first.data_type
  end

  def test_agrees_with_categorize
    a = CA_INT32([4, 8, 4, 1, 8, 8])
    codes, levels = a.factorize
    cat = a.categorize
    assert_equal cat.codes.to_a, codes.to_a
    assert_equal cat.labels, levels.to_a
  end

  def test_float_nan_collapses_as_unique_does
    a = CA_FLOAT64([0.0 / 0.0, 1.0, 0.0 / 0.0])
    codes, levels = a.factorize
    assert_equal 2, levels.elements
    assert_equal codes[0], codes[2]
  end

  def test_negative_zero_folds_with_positive_zero
    a = CA_FLOAT64([-0.0, 1.0, 0.0])
    codes, levels = a.factorize
    assert_equal 2, levels.elements
    assert_equal codes[0], codes[2]
  end

  def test_complex_is_refused
    assert_raise(CArray::DataTypeError) do
      CArray.cmplx128(3) { |i| Complex(i, 0) }.factorize
    end
  end

  # The reason a caller reaches for this rather than #unique: the codes are a
  # dense renumbering, so they address a value array directly.
  def test_codes_address_a_dense_array
    keys = CA_INT64([70, 12, 70, 55, 12, 70])
    codes, levels = keys.factorize
    total = CArray.double(levels.elements)
    keys.elements.times { |i| total[codes[i]] += 1.0 }
    assert_equal [3.0, 2.0, 1.0], total.to_a
    assert_equal [70, 12, 55], levels.to_a
  end

end

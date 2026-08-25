# Test for CArray#unique (value-hash discovery family, compressing member).
#
# Contract (PROPOSAL_UNIQ):
#   - Returns a 1-D CArray of distinct values in first-appearance order.
#   - sort: true returns them ascending.
#   - Masked cells never appear; all-masked yields an empty CArray.
#   - Numeric distinctness is `==` with two float exceptions: all NaN collapse
#     to one value; -0.0 == +0.0 (first-seen value kept, so a leading -0.0 keeps
#     its sign). Named `unique` (not `uniq`) precisely because of the NaN
#     collapse, which Ruby Array#uniq does not do.
#   - CA_OBJECT / CA_FIXLEN follow Ruby eql?/hash and keep self's dtype.

require "test/unit"
require "carray"

class TestUnique < Test::Unit::TestCase

  def test_integer_appearance_order
    a = CA_INT32([3, 1, 3, 2, 1, 3])
    assert_equal [3, 1, 2], a.unique.to_a
    assert_equal CA_INT32, a.unique.data_type
    assert_equal 1, a.unique.ndim
  end

  def test_sort_ascending
    assert_equal [1, 2, 3], CA_INT32([3, 1, 3, 2, 1]).unique(sort: true).to_a
  end

  def test_no_duplicates_identity
    assert_equal [5, 6, 7], CA_INT32([5, 6, 7]).unique.to_a
  end

  def test_multidim_row_major_flatten
    assert_equal [1, 2, 3], CA_INT32([[1, 2], [2, 3]]).unique.to_a
  end

  def test_uint_and_int64
    assert_equal [7, 3, 9], CA_UINT8([7, 3, 7, 9, 3]).unique.to_a
    assert_equal [-2, 4, -2].uniq, CA_INT64([-2, 4, -2, 4]).unique.to_a
  end

  def test_float_appearance_order
    a = CA_FLOAT64([1.5, 2.5, 1.5, 3.5, 2.5])
    assert_equal [1.5, 2.5, 3.5], a.unique.to_a
  end

  def test_nan_collapses_to_one
    nan = Float::NAN
    a = CA_FLOAT64([1.0, nan, 2.0, nan, 1.0, nan])
    u = a.unique
    assert_equal 3, u.size
    assert_equal 1.0, u[0]
    assert u[1].nan?
    assert_equal 2.0, u[2]
  end

  def test_distinct_nan_bit_patterns_collapse
    # A different NaN (inf - inf) still collapses with Float::NAN.
    nan1 = Float::NAN
    nan2 = Float::INFINITY - Float::INFINITY
    assert_equal 1, CA_FLOAT64([nan1, nan2, nan1]).unique.size
  end

  def test_signed_zero_collapses_first_seen_kept
    # +0.0 first -> +0.0 kept (1/x == +Inf)
    z = CA_FLOAT64([0.0, -0.0, 0.0]).unique
    assert_equal 1, z.size
    assert_equal Float::INFINITY, 1.0 / z[0]
    # -0.0 first -> -0.0 kept (1/x == -Inf)
    z2 = CA_FLOAT64([-0.0, 0.0]).unique
    assert_equal 1, z2.size
    assert_equal(-Float::INFINITY, 1.0 / z2[0])
  end

  def test_nan_sorts_last
    nan = Float::NAN
    u = CA_FLOAT64([3.0, nan, 1.0, 2.0, nan]).unique(sort: true)
    assert_equal [1.0, 2.0, 3.0], u[0..2].to_a
    assert u[3].nan?
  end

  def test_float32
    assert_equal [1.0, 2.0, 3.0], CA_FLOAT32([1.0, 2.0, 1.0, 3.0, 2.0]).unique.to_a
  end

  def test_masked_cells_excluded
    a = CA_INT32([5, 5, 7, 9, 7])
    a[1] = UNDEF
    assert_equal [5, 7, 9], a.unique.to_a
    assert_equal 0, a.unique.count_masked
  end

  def test_all_masked_is_empty
    b = CA_FLOAT64([1.0, 2.0])
    b.mask = [1, 1]
    assert_equal [], b.unique.to_a
    assert_equal 0, b.unique.size
  end

  def test_object_appearance_order_and_dtype
    o = CA_OBJECT([:x, :y, :x, :z, :y])
    o.mask = [0, 0, 0, 1, 0]
    assert_equal [:x, :y], o.unique.to_a          # masked :z excluded
    assert_equal CA_OBJECT, o.unique.data_type
  end

  def test_object_sort
    assert_equal [:a, :b, :c], CA_OBJECT([:c, :a, :b, :a]).unique(sort: true).to_a
  end

  def test_object_collapses_distinct_nan
    # Object path uses Ruby eql?/hash, but collapses every Float NaN to one
    # distinct value, matching the numeric path (the discovery family unifies
    # NaN even across distinct NaN objects).
    nan1 = Float::NAN
    nan2 = Float::INFINITY - Float::INFINITY   # a distinct NaN object
    o = CA_OBJECT([1.0, nan1, 2.0, nan2, 1.0])
    u = o.unique.to_a
    assert_equal 3, u.size
    assert_equal 1, u.count { |x| x.is_a?(Float) && x.nan? }
  end

  def test_object_non_nan_floats_follow_ruby_hash
    # Non-NaN Floats keep Ruby Hash semantics; -0.0 and +0.0 fold together
    # (Float#eql? treats them equal), exactly as a Ruby Hash key would.
    assert_equal 1, CA_OBJECT([0.0, -0.0, 0.0]).unique.size
  end

  def test_fixlen_keeps_dtype
    f = CArray.new(CA_FIXLEN, [4], bytes: 3)
    f[0] = "ab"; f[1] = "cd"; f[2] = "ab"; f[3] = "ef"
    u = f.unique
    assert_equal CA_FIXLEN, u.data_type
    assert_equal ["ab", "cd", "ef"], u.to_a.map { |s| s.delete("\x00") }
  end

  def test_no_uniq_alias
    # `unique`, not `uniq`: the name deliberately differs from Array#uniq
    # because of the NaN-collapse semantics.
    assert_equal false, CA_INT32([1, 2]).respond_to?(:uniq)
  end

end

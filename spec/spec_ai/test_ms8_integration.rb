# MS.8: integration + edge cases for the mask SET family redesign.
#
# Complements MS.1-MS.7 unit tests by pinning:
#   - chain composability across mask_eq / mask_invalid / mask_where
#   - cross-method consistency vs the indexer canonical idiom
#   - view (CABlock / CARefer) parents
#   - 2D / 3D shapes
#   - co-existence of in-place indexer and return-form sugar
#   - removed legacy methods raise NoMethodError (= loud breaking)

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestMS8Integration < Test::Unit::TestCase

  # ---- removed legacy methods raise NoMethodError ----------------------

  def test_maskout_removed
    a = CArray.int32(5).seq
    assert_raise(NoMethodError) { a.maskout(0) }
  end

  def test_maskout_bang_removed
    a = CArray.int32(5).seq
    assert_raise(NoMethodError) { a.maskout!(0) }
  end

  def test_unmask_copy_removed
    a = CArray.int32(5).seq
    a[2] = UNDEF
    assert_raise(NoMethodError) { a.unmask_copy(-1) }
  end

  # ---- chain composability ---------------------------------------------

  def test_chain_mask_eq_then_count_masked
    a = CArray.int32(10).seq.mod(3)
    # values: 0,1,2,0,1,2,0,1,2,0 -> 4 zeros
    assert_equal(4, a.mask_eq(0).count_masked)
  end

  def test_chain_mask_invalid_then_sum
    a = CArray.float64(6)
    a[0] = 1.0; a[1] = 0.0 / 0.0
    a[2] = 2.0; a[3] = 1.0 / 0.0
    a[4] = 3.0; a[5] = 4.0
    # sum of finites = 1 + 2 + 3 + 4 = 10
    assert_equal(10.0, a.mask_invalid.sum)
  end

  def test_chain_mask_where_then_mean
    a = CArray.float64(10).seq    # [0..9]
    # mask < 3: remaining = [3,4,5,6,7,8,9] -> mean = 6.0
    assert_equal(6.0, a.mask_where(:lt, 3.0).mean)
  end

  def test_chain_mask_eq_then_strip_mask
    a = CArray.int32(8).seq.mod(3)
    b = a.mask_eq(1).strip_mask(-99)
    refute(b.has_mask?)
    # 1 occurs at indices 1, 4, 7
    assert_equal(-99, b[1])
    assert_equal(-99, b[4])
    assert_equal(-99, b[7])
  end

  # ---- 2D / 3D shapes --------------------------------------------------

  def test_2d_mask_eq
    a = CArray.int32(3, 4).seq.mod(2)
    # 1's at every other cell
    b = a.mask_eq(1)
    assert_equal([3, 4], b.shape)
    assert_equal(6, b.count_masked)
  end

  def test_3d_mask_invalid
    a = CArray.float64(2, 2, 2).seq
    a[0, 0, 0] = 0.0 / 0.0
    a[1, 1, 1] = 1.0 / 0.0
    b = a.mask_invalid
    assert_equal([2, 2, 2], b.shape)
    assert_equal(2, b.count_masked)
  end

  def test_2d_strip_mask
    a = CArray.float64(3, 4).seq
    a[1, 2] = UNDEF
    a[2, 0] = UNDEF
    b = a.strip_mask(-1.5)
    refute(b.has_mask?)
    assert_in_delta(-1.5, b[1, 2], 1e-6)
    assert_in_delta(-1.5, b[2, 0], 1e-6)
  end

  # ---- cross-method consistency ----------------------------------------

  def test_mask_eq_vs_indexer_2d
    a = CArray.int32(3, 4).seq.mod(5)
    [0, 2, 4].each do |v|
      x = a.mask_eq(v)
      y = a.dup
      y[:eq, v] = UNDEF
      assert_equal(y.is_masked.to_a, x.is_masked.to_a, "v=#{v} 2D mismatch")
    end
  end

  def test_mask_where_vs_indexer_2d
    a = CArray.int32(3, 4).seq
    [:lt, :gt, :le, :ge].each do |op|
      [3, 7].each do |v|
        x = a.mask_where(op, v)
        y = a.dup
        y[op, v] = UNDEF
        assert_equal(y.is_masked.to_a, x.is_masked.to_a,
                     "#{op} #{v} 2D mismatch")
      end
    end
  end

  # ---- view parents (CABlock / CARefer) --------------------------------

  def test_block_view_to_ca_then_mask_eq
    a = CArray.int32(5, 5).seq.mod(3)
    # a[1..3, 1..3] is a CABlock view; materialise via to_ca first
    v = a[1..3, 1..3].to_ca
    b = v.mask_eq(1)
    assert_equal([3, 3], b.shape)
    # count of 1's in the 3x3 sub-block
    expected = v.eq(1).count(true)
    assert_equal(expected, b.count_masked)
  end

  # ---- mask SET + value replacement interaction ------------------------

  def test_indexer_value_then_mask_eq_chain
    # ca[:is_invalid] = 999 (value replace) then mask_eq(999)
    a = CArray.float64(5)
    a[0] = 1.0; a[1] = 0.0 / 0.0
    a[2] = 2.0; a[3] = 1.0 / 0.0
    a[4] = 3.0
    a[:is_invalid] = 999.0          # replace NaN/Inf with 999
    refute(a.has_mask?)
    b = a.mask_eq(999.0)            # now mask those 999 cells
    assert_equal([false, true, false, true, false], b.is_masked.to_a)
  end

  # ---- mask_invalid + chain with count_not_masked ----------------------

  def test_mask_invalid_then_count_not_masked
    a = CArray.float64(8).seq
    a[1] = 0.0 / 0.0
    a[3] = 1.0 / 0.0
    a[5] = -1.0 / 0.0
    # 3 invalid, 5 valid -> count_not_masked = 5
    assert_equal(5, a.mask_invalid.count_not_masked)
  end

  # ---- strip_mask + mask_eq chain --------------------------------------

  def test_mask_eq_strip_mask_round_trip
    a = CArray.int32(5).seq                   # [0,1,2,3,4]
    b = a.mask_eq(2).strip_mask(-7)           # mask 2, then strip with -7
    refute(b.has_mask?)
    assert_equal([0, 1, -7, 3, 4], b.to_a)
  end
end

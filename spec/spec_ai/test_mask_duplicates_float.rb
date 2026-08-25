# Test for the float path of the single-pass seen-set hash behind
# CArray#mask_duplicates (C __mask_duplicates__).
#
# Contract: mask_duplicates uses `==` with two value-based exceptions matching
# the discovery family (uniq/categorize) -- all NaN collapse to one distinct
# value (so the second and later NaN are duplicates) and +0.0 == -0.0
# (normalized to one key). The reference here is a Ruby seen-set that treats all
# NaN as one value, which is exactly the documented semantics.

require "test/unit"
require "carray"

class TestMaskDuplicatesFloat < Test::Unit::TestCase

  # Seen-set over a flat value list (the documented contract): `==` for ordinary
  # values, plus all NaN treated as one distinct value. Returns the boolean dup
  # flags per position.
  def ref_dup (vals)
    seen = []
    seen_nan = false
    vals.map do |v|
      if v.is_a?(Float) && v.nan?
        dup = seen_nan
        seen_nan = true
        dup
      else
        dup = seen.any? { |s| s == v }
        seen << v unless dup
        dup
      end
    end
  end

  def assert_flat (dtype, vals, msg)
    a = CArray.send(dtype, vals.size) { |i| vals[i] }
    got = a.mask_duplicates.is_masked.to_a
    assert_equal ref_dup(vals), got, msg
  end

  def test_basic_duplicates
    assert_flat(:float64, [1.5, 2.0, 1.5, 3.0, 2.0], "basic")
  end

  def test_all_same
    assert_flat(:float64, [3.0, 3.0, 3.0], "all same")
  end

  def test_no_duplicates
    assert_flat(:float64, [1.0, 2.0, 3.0, 4.0], "no dup")
  end

  def test_negative_zero_equals_positive_zero
    # -0.0 == +0.0, so the second/third zero are duplicates of the first.
    assert_flat(:float64, [-0.0, 0.0, -0.0, 0.0], "signed zero")
  end

  def test_nan_collapses
    # All NaN collapse to one distinct value: the first NaN is kept, later NaN
    # are duplicates. The non-NaN duplicate is marked too.
    a = CArray.float64(5) { |i| [Float::NAN, 1.0, Float::NAN, 1.0, Float::NAN][i] }
    assert_equal [false, false, true, true, true],
                 a.mask_duplicates.is_masked.to_a
  end

  def test_nan_and_zero_mixed
    assert_flat(:float64,
                [1.5, 2.0, 1.5, 0.0, -0.0, Float::NAN, Float::NAN],
                "nan + zero mixed")
  end

  def test_float32
    assert_flat(:float32, [1.0, 2.0, 1.0, 2.0, 2.0, 1.0], "float32")
  end

  def test_masked_cell_does_not_participate
    # A masked input cell stays masked and is excluded from dup judging; other
    # cells are judged as if it were absent.
    a = CArray.float64(6) { |i| [1.0, 9.0, 1.0, 2.0, 2.0, 1.0][i] }
    a[1] = UNDEF
    got = a.mask_duplicates.is_masked.to_a
    assert_equal [false, true, true, false, true, true], got
  end

  def test_per_axis_independent
    a = CArray.float64(2, 4) { |i, j| [[1.0, 1.0, 2.0, 3.0], [5.0, 6.0, 6.0, 5.0]][i][j] }
    assert_equal [[false, true, false, false], [false, false, true, true]],
                 a.mask_duplicates(axis: 1).is_masked.to_a
  end

  def test_flatten_multi_dim
    a = CArray.float64(2, 3) { |i, j| [[1.0, 2.0, 1.0], [3.0, 2.0, 4.0]][i][j] }
    # flatten order: 1,2,1,3,2,4 -> dup at the second 1 and second 2
    assert_equal [[false, false, true], [false, true, false]], a.mask_duplicates.is_masked.to_a
  end
end

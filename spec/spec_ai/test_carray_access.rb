# frozen_string_literal: true
#
# spec_ai/test_carray_access.rb
#
# Tests for carray_access.c — volatile VALUE fixes:
#
#   volatile VALUE out (×3) in ary_flatten_upto_level paths
#     -> triggered by nested Ruby Array assignment: ca[] = [[1,2],[3,4]]
#     -> three code paths depending on array shape:
#        (a) same shape as CArray  (e.g. 2D array -> CArray.int(2,3))
#        (b) shape mismatch / partial level (e.g. [[1,2,3],[4,5,6]] -> CArray.int(6))
#        (c) 3D nesting
#
#   volatile VALUE index in rb_ca_store2
#     -> triggered by multi-dimensional element store: ca[i,j] = val
#
# cf. spec/Features/feature_ref_store_spec.rb

$:.unshift(File.join(File.dirname(__FILE__), "..", "..", "lib"))

require "test/unit"
require "carray"

class TestCarrayAccess < Test::Unit::TestCase

  # ------------------------------------------------------------------
  # ary_flatten_upto_level : same-shape path
  # ------------------------------------------------------------------

  def test_nested_assign_2d_int
    a = CArray.int(2, 3)
    a[] = [[1, 2, 3],
           [4, 5, 6]]
    assert_equal CA_INT([[1, 2, 3],
                         [4, 5, 6]]), a
  end

  def test_nested_assign_2d_double
    a = CArray.double(2, 3)
    a[] = [[1.0, 2.0, 3.0],
           [4.0, 5.0, 6.0]]
    assert_equal CA_DOUBLE([[1.0, 2.0, 3.0],
                             [4.0, 5.0, 6.0]]), a
  end

  def test_nested_assign_square
    a = CArray.int(3, 3)
    a[] = [[1, 2, 3],
           [4, 5, 6],
           [7, 8, 9]]
    assert_equal CA_INT([[1, 2, 3],
                         [4, 5, 6],
                         [7, 8, 9]]), a
  end

  def test_nested_assign_3d
    a = CArray.int(2, 2, 2)
    a[] = [[[1, 2], [3, 4]],
           [[5, 6], [7, 8]]]
    assert_equal (1..8).to_a, a.flatten.to_a
  end

  # ------------------------------------------------------------------
  # ary_flatten_upto_level : shape-mismatch / partial-level path
  # ------------------------------------------------------------------

  def test_nested_assign_to_1d
    a = CArray.int(6)
    a[] = [[1, 2, 3], [4, 5, 6]]
    assert_equal CA_INT([1, 2, 3, 4, 5, 6]), a
  end

  def test_nested_assign_to_1d_object
    a = CArray.object(6)
    a[] = [[1, 2, 3], [4, 5, 6]]
    assert_equal [1, 2, 3, 4, 5, 6], a.to_a
  end

  # ------------------------------------------------------------------
  # rb_ca_store2 : multi-index point store (volatile VALUE index)
  # ------------------------------------------------------------------

  def test_store_point_2d
    a = CArray.int(3, 3).seq!
    a[1, 1] = -1
    assert_equal  4, CArray.int(3, 3).seq![1, 1]   # original
    assert_equal(-1, a[1, 1])
    assert_equal  0, a[0, 0]
    assert_equal  8, a[2, 2]
  end

  def test_store_point_negative_index
    a = CArray.int(3, 3).seq!
    a[-1, -1] = 99
    assert_equal 99, a[2, 2]
    assert_equal 99, a[-1, -1]
    assert_equal  0, a[0, 0]
  end

  def test_store_point_3d
    a = CArray.double(2, 2, 2)
    a[] = 0.0
    a[1, 0, 1] = 7.5
    assert_in_delta 7.5, a[1, 0, 1], 1e-10
    assert_in_delta 0.0, a[0, 0, 0], 1e-10
  end

  def test_store_point_all_elements
    a = CArray.int(4, 4)
    a[] = 0
    16.times { |k| a[k / 4, k % 4] = k + 1 }
    assert_equal CA_INT([[1,  2,  3,  4],
                         [5,  6,  7,  8],
                         [9,  10, 11, 12],
                         [13, 14, 15, 16]]), a
  end

  def test_store_point_out_of_bounds
    a = CArray.int(3, 3)
    assert_raise(IndexError) { a[0,  3] = 1 }
    assert_raise(IndexError) { a[-4, 0] = 1 }
  end

  # ------------------------------------------------------------------
  # GC stress : force GC on every allocation to exercise volatile paths
  # ------------------------------------------------------------------

  def test_nested_assign_gc_stress
    old_stress = GC.stress
    GC.stress = true
    begin
      10.times do
        a = CArray.int(3, 3)
        a[] = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
        assert_equal CA_INT([[1, 2, 3], [4, 5, 6], [7, 8, 9]]), a
      end
    ensure
      GC.stress = old_stress
    end
  end

  def test_store_point_gc_stress
    old_stress = GC.stress
    GC.stress = true
    begin
      a = CArray.int(4, 4)
      a[] = 0
      16.times { |k| a[k / 4, k % 4] = k + 1 }
      assert_equal CA_INT([[1,  2,  3,  4],
                           [5,  6,  7,  8],
                           [9,  10, 11, 12],
                           [13, 14, 15, 16]]), a
    ensure
      GC.stress = old_stress
    end
  end

  # ------------------------------------------------------------------
  # rb_ca_fill : an empty array returns self (not the fill value), so
  # fill stays chainable and callers relying on the return get a CArray.
  # ------------------------------------------------------------------

  def test_fill_empty_returns_self
    a = CArray.new(CA_INT64, [0])
    assert_equal 0, a.elements
    assert_same a, a.fill(0)
    assert_same a, a.fill(7)
  end

  def test_fill_copy_empty_returns_carray
    r = CArray.new(CA_INT64, [0]).fill_copy(0)
    assert_kind_of CArray, r
    assert_equal 0, r.elements
  end

  def test_fill_nonempty_returns_self_and_fills
    a = CArray.new(CA_INT64, [3])
    assert_same a, a.fill(9)
    assert_equal [9, 9, 9], a.to_a
  end

end

# frozen_string_literal: true
#
# SO.5 — order(axis:) per-fiber rank tests
# (PROPOSAL_SORT_AXIS rev7+).
#
# Pins:
#   - order(axis: 0) on a 1-D input matches the legacy flat order
#     (backward-compat property: per-fiber rank with single axis == flat rank)
#   - order(axis: k) on N-D returns CArray of int64, shape == self.shape
#   - Each fiber along axis is independently ranked
#   - Stable (= ordinal): tied values get distinct ranks in original
#     fiber order (= mkkernel :sort kind's stable contract)
#   - Descending (dir < 0) is (dim[axis] - 1) - ascending
#   - Mask handling: any actually masked -> raise; has-mask-field-but-
#     no-actually-masked -> strip via value, succeed (= sort method
#     convention from SO.2)
#   - axis OOR raise
#   - data_type: order returns CA_INT64 (= CA_SIZE, matches the rest of
#     the *_index family it's built on: sort_index / partition_index /
#     rank_index.  3.0 breaking: was CA_INT32 pre-unification.)

require "test/unit"
require "carray"

class TestOrderAxis < Test::Unit::TestCase

  # ---- 1-D axis: 0 matches flat order -----------------------------------

  def test_1d_axis_matches_flat
    a = CArray.int32(5)
    [3, 1, 4, 1, 5].each_with_index { |v, i| a[i] = v }
    assert_equal(a.order.to_a, a.order(axis: 0).to_a)
  end

  def test_1d_axis_negative
    a = CArray.int32(5)
    [3, 1, 4, 1, 5].each_with_index { |v, i| a[i] = v }
    assert_equal(a.order(axis: 0).to_a, a.order(axis: -1).to_a)
  end

  def test_1d_descending_matches_flat
    a = CArray.int32(5)
    [3, 1, 4, 1, 5].each_with_index { |v, i| a[i] = v }
    assert_equal(a.order(descending: true).to_a, a.order(axis: 0, descending: true).to_a)
  end

  # ---- 2-D axis 0 (per-column rank) -------------------------------------

  def test_2d_axis_0_per_column
    b = CArray.int32(3, 4)
    [[3,1,4,1], [5,9,2,6], [8,7,3,5]].each_with_index do |row, i|
      row.each_with_index { |v, j| b[i, j] = v }
    end
    # Per column:
    # col 0 = [3, 5, 8]   -> [0, 1, 2]
    # col 1 = [1, 9, 7]   -> [0, 2, 1]
    # col 2 = [4, 2, 3]   -> [2, 0, 1]
    # col 3 = [1, 6, 5]   -> [0, 2, 1]
    assert_equal([[0,0,2,0], [1,2,0,2], [2,1,1,1]], b.order(axis: 0).to_a)
  end

  def test_2d_axis_1_per_row
    b = CArray.int32(3, 4)
    [[3,1,4,1], [5,9,2,6], [8,7,3,5]].each_with_index do |row, i|
      row.each_with_index { |v, j| b[i, j] = v }
    end
    # Per row (stable for ties):
    # row 0 = [3, 1, 4, 1] -> [2, 0, 3, 1]
    # row 1 = [5, 9, 2, 6] -> [1, 3, 0, 2]
    # row 2 = [8, 7, 3, 5] -> [3, 2, 0, 1]
    assert_equal([[2,0,3,1], [1,3,0,2], [3,2,0,1]], b.order(axis: 1).to_a)
  end

  def test_2d_descending
    b = CArray.int32(2, 4)
    [[3,1,4,1], [5,9,2,6]].each_with_index do |row, i|
      row.each_with_index { |v, j| b[i, j] = v }
    end
    asc = b.order(axis: 1)
    desc = b.order(axis: 1, descending: true)
    # desc[i, j] == (4 - 1) - asc[i, j]
    b.dim[0].times do |i|
      b.dim[1].times do |j|
        assert_equal(3 - asc[i, j], desc[i, j],
                     "i=#{i}, j=#{j}: asc=#{asc[i,j]}, desc=#{desc[i,j]}")
      end
    end
  end

  # ---- shape and data_type --------------------------------------------------

  def test_axis_output_shape_equals_input
    a = CArray.int32(2, 3, 4).seq
    o = a.order(axis: 1)
    assert_equal(a.dim.to_a, o.dim.to_a)
  end

  def test_axis_output_data_type_is_int64
    a = CArray.float64(5).seq
    assert_equal(CA_INT64, a.order(axis: 0).data_type)
  end

  # ---- stable ties -------------------------------------------------------

  def test_stable_ties_per_fiber
    # All values equal in fiber -> all rank 0..n-1 in original order
    a = CArray.int32(2, 4)
    4.times { |j| a[0, j] = 7 }
    4.times { |j| a[1, j] = 7 }
    o = a.order(axis: 1)
    # Stable -> sequential 0,1,2,3 in each row
    assert_equal([[0,1,2,3], [0,1,2,3]], o.to_a)
  end

  # ---- 3-D --------------------------------------------------------------

  def test_3d_axis_middle
    a = CArray.int32(2, 5, 3)
    # Build fiber along axis 1 with known unique values per (i, k)
    2.times do |i|
      3.times do |k|
        [5, 1, 4, 2, 3].each_with_index { |v, j| a[i, j, k] = v + 10 * (i * 3 + k) }
      end
    end
    o = a.order(axis: 1)
    assert_equal([2, 5, 3], o.dim.to_a)
    2.times do |i|
      3.times do |k|
        fiber = (0...5).map { |j| a[i, j, k] }
        ranks = (0...5).map { |j| o[i, j, k] }
        sorted_fiber = fiber.sort
        # Each cell's rank = index in sorted_fiber
        fiber.each_with_index do |v, j|
          assert_equal(sorted_fiber.index(v), ranks[j],
                       "i=#{i}, k=#{k}, j=#{j}, fiber=#{fiber}, ranks=#{ranks}")
        end
      end
    end
  end

  # ---- error cases ------------------------------------------------------

  def test_axis_out_of_range
    a = CArray.int32(3, 4).seq
    assert_raise(ArgumentError) { a.order(axis: 2) }
    assert_raise(ArgumentError) { a.order(axis: -3) }
  end

  def test_actually_masked_skips_via_rank_index
    # 3.0 dual API rework: order is now backed by the rank_index kernel
    # (mask_self: :skip), which ranks the unmasked subsequence and
    # propagates UNDEF at masked positions instead of rejecting.
    a = CArray.float64(5).seq
    a[2] = UNDEF
    r = a.order(axis: 0)
    # unmasked values [0, 1, 3, 4] at axis positions [0, 1, 3, 4]
    # sorted asc -> ranks [0, 1, 2, 3] at those positions;
    # masked position 2 -> UNDEF.
    assert_equal [false, false, true, false, false],
                 r.is_masked.to_a
    assert_equal [0, 1, 2, 3], r.value[CA_INT([0, 1, 3, 4])].to_a
  end

  def test_has_mask_field_but_no_masked_passes
    # CASelect-style: parent's mask propagates as a field but the
    # selected cells are all unmasked.  Should succeed.
    a = CArray.float64(5)
    [3.0, 1.0, 4.0, 1.5, 5.0].each_with_index { |v, i| a[i] = v }
    a[2] = UNDEF
    # is_not_masked: parent has mask, selection contains unmasked only
    src = a[:is_not_masked]
    assert_predicate(src, :has_mask?)
    assert_not_predicate(src, :any_masked?)
    # Should not raise; strip via value
    result = src.order(axis: 0)
    assert_equal(4, result.elements)
  end

  # ---- legacy flat path still works -------------------------------------

  def test_legacy_flat_order_unchanged
    a = CArray.int32(3, 2)
    [[3, 1], [4, 1], [5, 2]].each_with_index do |row, i|
      row.each_with_index { |v, j| a[i, j] = v }
    end
    # Flat order = global rank reshaped
    expected = [[3, 0], [4, 1], [5, 2]]
    assert_equal(expected, a.order.to_a)
  end

end

# frozen_string_literal: true
#
# SO.2 — `sort(axis:)` view-by-default tests (PROPOSAL_SORT_AXIS rev6).
#
# Pins:
#   - `a.sort` (no-arg) returns 1-D CARemap view of flatten-then-sort
#     (= Q1(A) confirmed 2026-06-03, 3.0 breaking).
#   - `a.sort(axis: k)` returns N-D CARemap view, sorted along axis k,
#     shape preserved.
#   - View identity: a.sort.class == CARemap, not eager CArray.
#   - Values match per-fiber argsort.
#   - Chain composability: a.sort.to_ca eager copy; a.sort.reshape works.
#   - In-place idiom: `b[] = b.sort.reshape(*b.dim)`.
#   - Stable sort (= equal values keep original order within fiber).
#   - NaN end policy (= NumPy default).
#   - mask global raise.
#   - CA_FIXLEN falls back to eager flat-sort copy (= shape preserved,
#     legacy 2.x semantics).

require "test/unit"
require "carray"

class TestSortAxis < Test::Unit::TestCase

  # ---- no-arg form (= flatten + sort, 1-D view) -------------------------

  def test_no_arg_returns_caremap_1d_view
    a = CArray.int32(3, 3)
    [[5,4,3], [0,1,2], [8,7,6]].each_with_index do |row, i|
      row.each_with_index { |v, j| a[i, j] = v }
    end
    s = a.sort
    assert_equal(CARemap, s.class)
    assert_equal([9], s.dim.to_a)
    assert_equal([0,1,2,3,4,5,6,7,8], s.to_a)
  end

  def test_no_arg_eager_to_ca
    a = CArray.int32(4)
    [3, 1, 4, 2].each_with_index { |v, i| a[i] = v }
    e = a.sort.to_ca
    assert_kind_of(CArray, e)
    assert_equal([1, 2, 3, 4], e.to_a)
  end

  def test_no_arg_reshape_to_2d
    a = CArray.int32(2, 3)
    [[3, 1, 2], [6, 5, 4]].each_with_index do |row, i|
      row.each_with_index { |v, j| a[i, j] = v }
    end
    # Flatten-then-sort + reshape back to original
    reshaped = a.sort.reshape(*a.dim)
    assert_equal([2, 3], reshaped.dim.to_a)
    assert_equal([[1, 2, 3], [4, 5, 6]], reshaped.to_a)
  end

  # ---- axis: kwarg form (= N-D view, shape preserved) -------------------

  def test_axis_0_sorts_each_column
    a = CArray.int32(3, 3)
    [[5,4,3], [0,1,2], [8,7,6]].each_with_index do |row, i|
      row.each_with_index { |v, j| a[i, j] = v }
    end
    s = a.sort(axis: 0)
    assert_equal(CARemap, s.class)
    assert_equal([3, 3], s.dim.to_a)
    # Per column:
    #   col 0 = [5,0,8] sorted = [0,5,8]
    #   col 1 = [4,1,7] sorted = [1,4,7]
    #   col 2 = [3,2,6] sorted = [2,3,6]
    assert_equal([[0, 1, 2], [5, 4, 3], [8, 7, 6]], s.to_a)
  end

  def test_axis_1_sorts_each_row
    a = CArray.int32(3, 3)
    [[5,4,3], [0,1,2], [8,7,6]].each_with_index do |row, i|
      row.each_with_index { |v, j| a[i, j] = v }
    end
    s = a.sort(axis: 1)
    assert_equal([3, 3], s.dim.to_a)
    assert_equal([[3, 4, 5], [0, 1, 2], [6, 7, 8]], s.to_a)
  end

  def test_axis_negative
    a = CArray.int32(2, 4)
    [[4,2,3,1], [8,6,7,5]].each_with_index do |row, i|
      row.each_with_index { |v, j| a[i, j] = v }
    end
    assert_equal(a.sort(axis: 1).to_a, a.sort(axis: -1).to_a)
    assert_equal(a.sort(axis: 0).to_a, a.sort(axis: -2).to_a)
  end

  def test_3d_axis_middle
    a = CArray.int32(2, 3, 2).seq
    s = a.sort(axis: 1)
    assert_equal([2, 3, 2], s.dim.to_a)
    # Per-(i, *, k) fiber along axis 1: a has seq values so already sorted
    a.dim[0].times do |i|
      a.dim[2].times do |k|
        fiber_orig = (0...a.dim[1]).map { |j| a[i, j, k] }
        fiber_sort = (0...a.dim[1]).map { |j| s[i, j, k] }
        assert_equal(fiber_orig.sort, fiber_sort,
                     "fiber (i=#{i}, k=#{k}): orig=#{fiber_orig}")
      end
    end
  end

  # ---- in-place idiom ---------------------------------------------------

  def test_in_place_via_self_assignment_2d
    b = CArray.int32(3, 3)
    [[5,4,3], [0,1,2], [8,7,6]].each_with_index do |row, i|
      row.each_with_index { |v, j| b[i, j] = v }
    end
    # Canonical idiom: ca[] = ca.sort.reshape(*ca.dim)
    b[] = b.sort.reshape(*b.dim)
    assert_equal([[0, 1, 2], [3, 4, 5], [6, 7, 8]], b.to_a)
  end

  def test_in_place_axis_via_self_assignment
    b = CArray.int32(3, 3)
    [[5,4,3], [0,1,2], [8,7,6]].each_with_index do |row, i|
      row.each_with_index { |v, j| b[i, j] = v }
    end
    b[] = b.sort(axis: 1)
    assert_equal([[3,4,5], [0,1,2], [6,7,8]], b.to_a)
  end

  # ---- stability (= equal values keep original fiber order) --------------

  def test_stable_axis_0
    a = CArray.int32(2, 3)
    # column 0: [2, 2] (equal), column 1: [1, 1], column 2: [3, 3]
    # All ties; stable sort preserves row 0 -> row 1 ordering
    [[2, 1, 3], [2, 1, 3]].each_with_index do |row, i|
      row.each_with_index { |v, j| a[i, j] = v }
    end
    s = a.sort(axis: 0)
    # No reordering since all values equal per column
    assert_equal([[2, 1, 3], [2, 1, 3]], s.to_a)
  end

  # ---- NaN policy :end --------------------------------------------------

  def test_nan_end_axis
    a = CArray.float64(2, 4)
    [[3.0, Float::NAN, 1.0, 2.0],
     [Float::NAN, 4.0, Float::NAN, 0.5]].each_with_index do |row, i|
      row.each_with_index { |v, j| a[i, j] = v }
    end
    s = a.sort(axis: 1)
    # Row 0: non-NaN sorted [1.0, 2.0, 3.0] + NaN at end
    assert_equal([1.0, 2.0, 3.0], s[0, 0..2].to_a)
    assert_predicate(s[0, 3].to_f, :nan?)
    # Row 1: non-NaN sorted [0.5, 4.0] + 2 NaN at end
    assert_equal([0.5, 4.0], s[1, 0..1].to_a)
    assert_predicate(s[1, 2].to_f, :nan?)
    assert_predicate(s[1, 3].to_f, :nan?)
  end

  # ---- mask sorts to masked_position -------------------------------------

  def test_masked_input_sorts_to_masked_position_no_arg
    a = CArray.int32(5).seq
    a[2] = UNDEF
    s = a.sort
    assert_equal([0, 1, 3, 4, UNDEF], s.to_a)
    assert_equal([false, false, false, false, true], s.mask.to_a)

    s_first = a.sort(masked_position: :first)
    assert_equal([UNDEF, 0, 1, 3, 4], s_first.to_a)
    assert_equal([true, false, false, false, false], s_first.mask.to_a)
  end

  def test_masked_input_sorts_to_masked_position_axis
    a = CArray.float64(3, 3).seq
    a[1, 1] = UNDEF                             # column 1: [1.0, UNDEF, 7.0]
    s = a.sort(axis: 0)
    assert_equal([1.0, 7.0, UNDEF], s[nil, 1].to_a)
    assert_equal([false, false, true], s[nil, 1].mask.to_a)
  end

  # ---- view chain transparency ------------------------------------------

  def test_view_chain_transpose
    a = CArray.int32(3, 4).seq
    tv = a.transpose                # shape (4, 3)
    s = tv.sort(axis: 0)             # sort each column of transposed view
    assert_equal([4, 3], s.dim.to_a)
    s.dim[1].times do |j|
      column = (0...s.dim[0]).map { |i| tv[i, j] }
      assert_equal(column.sort, (0...s.dim[0]).map { |i| s[i, j] },
                   "column j=#{j}: tv values=#{column}")
    end
  end

  def test_view_chain_block
    a = CArray.int32(10, 10).seq
    bv = a[3..7, 2..6]               # shape (5, 5)
    s = bv.sort(axis: 1)
    assert_equal([5, 5], s.dim.to_a)
    bv.dim[0].times do |i|
      row = (0...bv.dim[1]).map { |j| bv[i, j] }
      assert_equal(row.sort, (0...bv.dim[1]).map { |j| s[i, j] },
                   "row i=#{i}: bv values=#{row}")
    end
  end

  # ---- data_type coverage ---------------------------------------------------

  def test_axis_sort_various_int_data_types
    src = [[3, 1, 2], [6, 5, 4]]
    expected = [[1, 2, 3], [4, 5, 6]]
    %i[int8 uint8 int16 uint16 int32 uint32 int64 uint64].each do |dt|
      a = CArray.send(dt, 2, 3)
      src.each_with_index do |row, i|
        row.each_with_index { |v, j| a[i, j] = v }
      end
      assert_equal(expected, a.sort(axis: 1).to_a, "data_type #{dt}")
    end
  end

  def test_axis_sort_float_data_types
    src = [[3.5, 1.5, 2.5], [6.0, 5.5, 4.5]]
    expected = [[1.5, 2.5, 3.5], [4.5, 5.5, 6.0]]
    %i[float32 float64].each do |dt|
      a = CArray.send(dt, 2, 3)
      src.each_with_index do |row, i|
        row.each_with_index { |v, j| a[i, j] = v }
      end
      assert_equal(expected, a.sort(axis: 1).to_a, "data_type #{dt}")
    end
  end

  # ---- CA_FIXLEN unified onto the sort_addr_ki dialect ------------------

  def test_fixlen_flat_sort_returns_1d_view
    # CA_FIXLEN flows through the sort_addr_ki fixlen dialect + remap, same
    # as numeric: no-axis flattens to a 1-D CARemap view (3.0 unification,
    # was a shape-preserving eager copy under the old legacy path).
    a = CArray.fixlen(3, bytes: 2)
    %w[bb aa cc].each_with_index { |v, i| a[i] = v }
    s = a.sort
    assert_equal(CARemap, s.class)   # view-by-default, like numeric
    assert_equal([3], s.shape)       # 1-D already, flatten is a no-op here
    assert_equal(%w[aa bb cc], s.to_a)
  end

  # ---- axis out-of-range ------------------------------------------------

  def test_axis_out_of_range
    a = CArray.int32(3, 4).seq
    assert_raise(ArgumentError) { a.sort(axis: 2) }
    assert_raise(ArgumentError) { a.sort(axis: -3) }
  end

  # ---- argument validation ----------------------------------------------

  def test_rejects_positional_args
    a = CArray.int32(5).seq
    assert_raise(ArgumentError) { a.sort(0) }
  end

end

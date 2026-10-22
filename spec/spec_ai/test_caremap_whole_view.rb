# spec_ai/test_caremap_whole_view.rb
#
# Reading or writing a whole CARemap (`copy`, `to_a`, a reduction,
# `v[] = x`) reads the index array's cells as the parent addresses.  The
# answers match the cell-by-cell reads for every element width, and an
# index changed through `mapper` after the view was made is checked when
# the view is read: a negative one counts from the end, one out of range
# raises before the parent is touched.

require "test/unit"
require "carray"

class TestCARemapWholeView < Test::Unit::TestCase

  PERM = [5, 3, 0, 11, 7, 1, 9, 2, 10, 4, 8, 6]

  def index
    CArray.int64(3, 4) { PERM.dup }
  end

  def expected (a)
    flat = a.to_a.flatten
    PERM.map { |k| flat[k] }.each_slice(4).to_a
  end

  def test_every_element_width
    [:boolean, :int8, :uint16, :int32, :float32, :float64,
     :cmplx64, :cmplx128, :object].each do |t|
      seq = CArray.int32(3, 4).seq!
      a = ( t == :boolean ) ? ( seq % 3 ).eq(0) : seq.to_type(t)
      v = a[index]
      assert_kind_of CARemap, v, t.to_s
      assert_equal expected(a), v.copy.to_a, t.to_s
      assert_equal expected(a), v.to_a, t.to_s
    end
  end

  def test_fixlen_width_not_a_power_of_two
    a = CArray.fixlen(3, 4, bytes: 3)
    a[] = (0...12).map { |k| format("%03d", k) }
    assert_equal expected(a), a[index].copy.to_a
  end

  def test_reduction_reads_the_mapped_cells
    a = CArray.float64(3, 4).seq!
    assert_equal PERM.sum.to_f, a[index].sum
    assert_equal expected(a).map(&:sum), a[index].sum(axis: 1).to_a
  end

  def test_whole_view_write
    a = CArray.int32(3, 4).seq!
    a[index][] = CArray.int32(3, 4) { (100...112).to_a }
    PERM.each_with_index { |k, i| assert_equal 100 + i, a.to_a.flatten[k] }
    a[index][] = 7
    assert_equal [7] * 12, a.to_a.flatten
  end

  def test_masked_parent
    a = CArray.int32(3, 4).seq!
    a[0, 0] = UNDEF
    v = a[index].copy
    assert_equal [[false, false, true, false]] + [[false] * 4] * 2,
                 v.is_masked.to_a
  end

  def test_negative_mapper_cell_counts_from_the_end
    a = CArray.int32(3, 4).seq!
    v = a[index]
    v.mapper[0, 0] = -1
    assert_equal 11, v.copy[0, 0]
    assert_equal -1, v.mapper[0, 0]
    v[] = 0
    assert_equal 0, a[2, 3]
  end

  def test_out_of_range_mapper_cell_raises_before_the_parent_is_touched
    a = CArray.int32(3, 4).seq!
    v = a[index]
    [12, -13].each do |bad|
      v.mapper[2, 3] = bad
      assert_raise(IndexError, bad.to_s) { v.copy }
      assert_raise(IndexError, bad.to_s) { v[] = 99 }
      assert_equal (0..11).to_a, a.to_a.flatten
    end
  end

  # The parent is a strided view with no buffer of its own, so each
  # address is translated to the root's address axis by axis.
  def test_strided_parent_of_every_rank
    srand(7)
    [[6, 5], [4, 3, 5], [3, 2, 4, 3], [2, 3, 2, 2, 3]].each do |shape|
      root = CArray.int32(*shape).seq!
      [root.transpose,
       root.reshape(*shape.reverse).transpose,
       root.transpose(*(0...shape.size).to_a.rotate)].each do |parent|
        perm = (0...parent.elements).to_a.shuffle
        idx  = CArray.int64(perm.size) { |k| perm[k] }.reshape(*parent.shape).copy
        want = parent.copy.to_a.flatten
        v    = parent[idx]
        assert_kind_of CARemap, v
        assert_equal perm.map { |k| want[k] }, v.copy.to_a.flatten, shape.inspect
        v[] = CArray.int32(perm.size) { |k| -k - 1 }.reshape(*parent.shape)
        got = parent.copy.to_a.flatten
        perm.each_with_index { |k, j| assert_equal(-j - 1, got[k]) }
      end
    end
  end

  def test_stepped_slice_parent
    root = CArray.int32(8, 9).seq!
    parent = root[(1..7).step(2), (8..0).step(-3)]
    perm = (0...parent.elements).to_a.reverse
    idx  = CArray.int64(perm.size) { |k| perm[k] }.reshape(*parent.shape).copy
    assert_equal parent.copy.to_a.flatten.reverse, parent[idx].copy.to_a.flatten
  end

  def test_sort_axis_view
    a = CArray.float64(3, 4) { [3, 1, 2, 0, 9, 8, 7, 6, 4, 5, 11, 10].map(&:to_f) }
    assert_equal a.to_a.map(&:sort), a.sort(axis: 1).copy.to_a
  end

end

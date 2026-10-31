require "test/unit"
require "carray"

# Defects found by walking random chains of views against a table of root
# addresses.  Each test is the shortest chain that showed its defect.
class TestViewChainRegressions < Test::Unit::TestCase

  # Leaves the lazy scratch full of values no test below expects.
  def dirty_scratch
    (CArray.float64(4096).seq!.lazy * 2 + 7).sum
    (CArray.int32(4096).seq!.lazy + 7).sum
  end

  def cell(type, value)
    a = CArray.new(type, [1, 1])
    a[0] = value
    a
  end

  # --- lazy expressions of one cell read over several cells ----------------

  def test_one_cell_binop_read_through_a_broadcast
    dirty_scratch
    v = (cell(:float64, 1.5).lazy + 0).broadcast_to(4, 4)
    assert_equal [1.5] * 16, v.to_a.flatten
    dirty_scratch
    assert_equal [1.5] * 16, v.copy.to_a.flatten
    dirty_scratch
    assert_equal 24.0, v.sum
  end

  def test_one_cell_binop_read_through_a_tile_and_an_index_array
    dirty_scratch
    assert_equal [1.5] * 9, (cell(:float64, 1.5).lazy + 0).tile(3, 3).to_a.flatten
    dirty_scratch
    assert_equal [3] * 6, (cell(:int32, 3).lazy + 0)[CA_INT64([0, 0, 0, 0, 0, 0])].to_a
  end

  def test_one_cell_comparison_read_through_a_broadcast
    dirty_scratch
    assert_equal [true] * 9, cell(:int32, 3).lazy.eq(3).broadcast_to(3, 3).to_a.flatten
    dirty_scratch
    assert_equal [false] * 9, cell(:int32, 3).lazy.lt(3).broadcast_to(3, 3).to_a.flatten
  end

  def test_one_cell_three_operand_expressions_read_through_a_broadcast
    f = cell(:float64, 1.5)
    dirty_scratch
    assert_equal [4.0] * 9, f.lazy.fma(2, 1).broadcast_to(3, 3).to_a.flatten
    dirty_scratch
    assert_equal [1.0] * 9, f.lazy.clip(0, 1).broadcast_to(3, 3).to_a.flatten
    dirty_scratch
    assert_equal [1.5] * 9, f.lazy.gt(1).then_else(f.lazy, 0).broadcast_to(3, 3).to_a.flatten
  end

  def test_one_cell_chain_and_fuse_read_through_a_broadcast
    f = cell(:float64, 1.5)
    dirty_scratch
    assert_equal [4.0] * 9, (f.lazy * 2 + 1).broadcast_to(3, 3).to_a.flatten
    dirty_scratch
    assert_equal [3.0] * 9, CArray.fuse { f * 2 }.broadcast_to(3, 3).to_a.flatten
  end

  def test_one_cell_masked_operand_stays_masked_over_every_cell
    m = cell(:float64, UNDEF)
    dirty_scratch
    assert_equal [true] * 9, (m.lazy + 0).broadcast_to(3, 3).is_masked.to_a.flatten
  end

  # --- writes through a view of a parent whose cells overlap ---------------

  def overlap_view
    a = CArray.int32(12).seq!
    [a, a.sliding_windows(3).diagonal]
  end

  def test_in_place_operations_reach_every_cell_of_the_view
    want = [100, 1, 102, 3, 104, 5, 6, 7, 8, 9, 10, 11]

    a, v = overlap_view
    v.add!(100)
    assert_equal want, a.to_a

    a, v = overlap_view
    v.map! { |x| x + 100 }
    assert_equal want, a.to_a

    a, v = overlap_view
    v[] = v + 100
    assert_equal want, a.to_a
  end

  def test_seq_reaches_every_cell_of_the_view
    a, v = overlap_view
    v.seq!(100)
    assert_equal [100, 1, 101, 3, 102, 5, 6, 7, 8, 9, 10, 11], a.to_a
  end

  def test_mask_writes_reach_every_cell_of_the_view
    a, v = overlap_view
    v.invert_mask
    assert_equal [0, 2, 4], a.is_masked.to_a.each_index.select { |i| a.is_masked[i] }

    a, v = overlap_view
    v[] = UNDEF
    v.unmask(7)
    assert_equal [7, 1, 7, 3, 7, 5, 6, 7, 8, 9, 10, 11], a.to_a
    assert_equal 0, a.count_masked
  end

  def test_views_of_overlapping_parents_that_select_cells
    a = CArray.int32(6).seq!
    a.sliding_windows(3)[CA_INT64([0, 5, 10])].add!(100)
    assert_equal [100, 1, 2, 103, 104, 5], a.to_a

    a = CArray.int32(6).seq!
    w = a.sliding_windows(3)
    w[CA_BOOLEAN([1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]).reshape(4, 3)].add!(100)
    assert_equal [100, 1, 102, 3, 104, 5], a.to_a

    a = CArray.int32(6).seq!
    a.sliding_windows(3)[CA_INT64([0, 2]), CA_INT64([1])].map! { |x| x + 100 }
    assert_equal [0, 101, 2, 103, 4, 5], a.to_a
  end

  def test_a_reshape_of_an_overlapping_parent
    a = CArray.int32(6).seq!
    a.sliding_windows(3).reshape(3, 4)[CA_INT64([0, 1]), CA_INT64([0])].add!(100)
    assert_equal [100, 1, 102, 3, 4, 5], a.to_a
  end
end

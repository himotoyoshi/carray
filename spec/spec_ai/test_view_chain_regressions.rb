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
end

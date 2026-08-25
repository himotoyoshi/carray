require "carray"
require "test/unit"

# Tests for CArray.align_addr (ALIGN.1, 2026-07-07): the symmetric N-ary
# coordinate-alignment counterpart of the instance method locate_addr.

class TestAlignAddr < Test::Unit::TestCase

  def test_outer_common_and_indices
    a = CA_INT([10, 20, 30])
    b = CA_INT([20, 30, 40])
    common, ia, ib = CArray.align_addr(a, b, join: :outer)
    assert_equal [10, 20, 30, 40], common.to_a
    assert_equal [0, 1, 2], [ia[0], ia[1], ia[2]]
    assert_equal true, ia.mask[3]                 # a lacks 40
    assert_equal true, ib.mask[0]                 # b lacks 10
    assert_equal [0, 1, 2], [ib[1], ib[2], ib[3]]
  end

  def test_outer_reindex_roundtrip
    a = CA_INT([10, 20, 30]);   av = CA_DOUBLE([1.0, 2.0, 3.0])
    b = CA_INT([20, 30, 40]);   bv = CA_DOUBLE([2.2, 3.3, 4.4])
    common, ia, ib = CArray.align_addr(a, b, join: :outer)
    ag = av.project(ia)
    bg = bv.project(ib)
    assert_equal common.shape, ag.shape
    assert_equal [1.0, 2.0, 3.0], [ag[0], ag[1], ag[2]]
    assert_equal true, ag.mask[3]                 # a has no value at 40
    assert_equal true, bg.mask[0]                 # b has no value at 10
    assert_equal [2.2, 3.3, 4.4], [bg[1], bg[2], bg[3]]
  end

  def test_inner_is_intersection_of_all
    a = CA_INT([10, 20, 30])
    b = CA_INT([20, 30, 40])
    c = CA_INT([30, 20])
    common, = CArray.align_addr(a, b, c, join: :inner)
    assert_equal [20, 30], common.to_a         # present in every array, a's order
  end

  def test_left_and_right
    a = CA_INT([10, 20, 30])
    b = CA_INT([20, 30, 40])
    assert_equal [10, 20, 30], CArray.align_addr(a, b, join: :left)[0].to_a
    assert_equal [20, 30, 40], CArray.align_addr(a, b, join: :right)[0].to_a
  end

  def test_indices_map_into_each_array
    a = CA_INT([30, 10, 50, 0, 20, 40])       # unsorted
    b = CA_INT([20, 40])
    common, ia, ib = CArray.align_addr(a, b, join: :outer)
    # every non-masked idx gathers the matching common value
    common.elements.times do |j|
      assert_equal common[j], a[ia[j]] unless ia.mask && ia.mask[j]
      assert_equal common[j], b[ib[j]] unless ib.mask && ib.mask[j]
    end
  end

  def test_single_array_degenerate
    common, idx = CArray.align_addr(CA_INT([5, 5, 7]), join: :outer)
    assert_equal [5, 7], common.to_a           # distinct values
    assert_equal [0, 2], idx.to_a              # first occurrence addresses
    assert_equal false, idx.has_mask?
  end

  def test_object_lane
    a = CArray.object(2) { |i| %w[x y][i] }
    b = CArray.object(2) { |i| %w[y z][i] }
    common, ia, ib = CArray.align_addr(a, b, join: :outer)
    assert_equal ["x", "y", "z"], common.to_a
    assert_equal [0, 1], [ia[0], ia[1]]
    assert_equal true, ia.mask[2]                 # a lacks "z"
    assert_equal true, ib.mask[0]                 # b lacks "x"
  end

  def test_rejects_bad_join
    assert_raise(ArgumentError) { CArray.align_addr(CA_INT([1]), join: :cross) }
  end

  def test_rejects_empty
    assert_raise(ArgumentError) { CArray.align_addr(join: :outer) }
  end

  # ---- align_nearest_addr (ALIGN.2): ordered lane, reference grid -----------

  # idx_k is grid-shaped: each grid point -> nearest address into arrays[k],
  # OOB grid points masked. Grid points chosen exactly on the array values to
  # avoid rounding ambiguity.
  def test_nearest_grid_align
    grid = CA_DOUBLE([0.0, 10.0, 20.0, 30.0])
    a = CA_DOUBLE([10.0, 20.0])
    b = CA_DOUBLE([20.0, 30.0])
    common, ia, ib = CArray.align_nearest_addr(a, b, grid: grid)
    assert_equal grid.to_a, common.to_a
    assert_equal [true, false, false, true], ia.mask.to_a   # 0 and 30 OOB for a=[10,20]
    assert_equal [0, 1], [ia[1], ia[2]]
    assert_equal [true, true, false, false], ib.mask.to_a   # 0 and 10 OOB for b=[20,30]
    assert_equal [0, 1], [ib[2], ib[3]]
  end

  def test_nearest_reindex_roundtrip
    grid = CA_DOUBLE([0.0, 10.0, 20.0, 30.0])
    a = CA_DOUBLE([10.0, 20.0]);  adata = CA_DOUBLE([1.0, 2.0])
    _common, ia, = CArray.align_nearest_addr(a, grid: grid)
    ag = adata.project(ia)
    assert_equal [1.0, 2.0], [ag[1], ag[2]]
    assert_equal [true, false, false, true], ag.mask.to_a
  end

  def test_nearest_grid_defaults_to_first_array_verbatim
    a = CA_DOUBLE([12.0, 27.0, 8.0])
    b = CA_DOUBLE([9.0, 25.0])
    common, = CArray.align_nearest_addr(a, b)
    assert_equal [12.0, 27.0, 8.0], common.to_a   # first array kept as-is
  end

  # :round and :floor pick different neighbours at a midpoint-ish grid point.
  def test_nearest_direction_forwarded
    grid = CA_DOUBLE([0.0, 10.0, 20.0, 30.0, 40.0])
    a = CA_DOUBLE([15.0, 35.0])
    _c, jr = CArray.align_nearest_addr(a, grid: grid, direction: :round)
    assert_equal 1, jr[3]                         # 30 -> 35 (nearest)  @1
    _c, jf = CArray.align_nearest_addr(a, grid: grid, direction: :floor)
    assert_equal 0, jf[3]                         # 30 -> 15 (floor)    @0
  end

  def test_nearest_tolerance_masks_far
    grid = CA_DOUBLE([10.0, 20.0])
    a = CA_DOUBLE([8.0, 40.0])                    # both grid points in [8,40]
    _c, j = CArray.align_nearest_addr(a, grid: grid, tolerance: 3.0)
    assert_equal 0, j[0]                          # 10 -> 8, d2 <= 3 kept
    assert_equal true, j.mask[1]                     # 20 -> 8, d12 > 3 masked
  end

  def test_nearest_grid_explicit_last_array
    a = CA_DOUBLE([10.0, 20.0])
    b = CA_DOUBLE([0.0, 10.0, 20.0, 30.0])
    common, = CArray.align_nearest_addr(a, b, grid: b)
    assert_equal b.to_a, common.to_a
  end

  def test_nearest_rejects_empty
    assert_raise(ArgumentError) { CArray.align_nearest_addr }
  end

  def test_nearest_rejects_bad_direction
    grid = CA_DOUBLE([0.0, 10.0])
    assert_raise(ArgumentError) do
      CArray.align_nearest_addr(CA_DOUBLE([5.0]), grid: grid, direction: :nearest)
    end
  end

end

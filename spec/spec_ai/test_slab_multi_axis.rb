# PROPOSAL_SLAB_FAMILY β.xc — multi-axis slab tests
#
# Scope (= β.xc first cut):
#   - each_slab(axis: [k1, k2, ...]): K-D slab yield, side-effect only
#   - reduce_slab(axis: [k1, k2, ...]): output shape = src.dim with K axes
#     removed; per-slab block scalar return; per-element fiber inject
#   - mask transparent carry (= same plumbing as data side, inherited
#     from β.xb)
#   - Restriction: ALIAS mode only AND slab must be row-major contig in
#     src memory (= innermost K axes of contig source, or equivalent).
#     Non-contig multi-axis slabs raise NotImplementedError (β.xc')
#   - map_slab multi-axis: still raises NotImplementedError (= WRITE-side
#     scatter for K-D output is deferred)

require 'test/unit'
require 'carray'

class TestSlabMultiAxisBetaXc < Test::Unit::TestCase

  # ---- each_slab multi-axis (= contig case)

  def test_each_slab_innermost_two_axes
    a = CArray.float64(2, 3, 4).seq!
    seen_sums = []
    a.each_slab(axis: [1, 2]) { |slab| seen_sums << slab.sum }
    # slab 0 = a[0,:,:] = sum(0..11) = 66
    # slab 1 = a[1,:,:] = sum(12..23) = 66 + 12*12 = 210
    assert_equal [66.0, 210.0], seen_sums
  end

  def test_each_slab_innermost_two_axes_shape_and_ndim
    a = CArray.float64(2, 3, 4).seq!
    seen_dims = []
    a.each_slab(axis: [1, 2]) { |slab| seen_dims << [slab.ndim, slab.dim.to_a] }
    assert_equal [[2, [3, 4]], [2, [3, 4]]], seen_dims
  end

  def test_each_slab_flatten_all_axes
    a = CArray.float64(2, 3, 4).seq!
    count = 0
    sums = []
    a.each_slab(axis: [0, 1, 2]) { |slab| count += 1; sums << slab.sum }
    # Reducing all axes = one slab over the whole array
    assert_equal 1, count
    assert_equal [276.0], sums    # sum(0..23) = 276
  end

  # ---- each_slab multi-axis derived view (clone-path pin) preservation

  def test_each_slab_multi_axis_dup_per_iter
    a = CArray.float64(2, 3, 4).seq!
    snapshots = []
    a.each_slab(axis: [1, 2]) { |slab| snapshots << slab.dup }
    # First snapshot should hold a[0,:,:], second should hold a[1,:,:]
    assert_equal a[0, nil, nil].to_a, snapshots[0].to_a
    assert_equal a[1, nil, nil].to_a, snapshots[1].to_a
  end

  # ---- reduce_slab per-slab multi-axis

  def test_reduce_slab_per_slab_innermost_two_axes
    a = CArray.float64(2, 3, 4).seq!
    r = a.reduce_slab(axis: [1, 2]) { |slab| slab.sum }
    assert_equal [2],            r.dim.to_a
    assert_equal [66.0, 210.0], r.to_a
  end

  def test_reduce_slab_per_slab_3d_max_along_inner
    a = CArray.int32(2, 3, 4).seq!
    r = a.reduce_slab(axis: [1, 2]) { |slab| slab.max }
    assert_equal [11, 23], r.to_a   # a[0,:,:].max=11; a[1,:,:].max=23
  end

  def test_reduce_slab_per_slab_flatten_all_axes_to_length_one
    a = CArray.float64(2, 3, 4).seq!
    r = a.reduce_slab(axis: [0, 1, 2]) { |slab| slab.sum }
    assert_equal [1],     r.dim.to_a
    assert_equal [276.0], r.to_a
  end

  def test_reduce_slab_4d_innermost_two_axes
    a = CArray.float64(2, 2, 3, 4).seq!
    r = a.reduce_slab(axis: [2, 3]) { |slab| slab.sum }
    # Output shape (2, 2); each slab is shape (3, 4) summed
    assert_equal [2, 2], r.dim.to_a
    # First slab a[0,0,:,:] sum = 0..11 → 66
    # Last slab a[1,1,:,:] sum = 36..47 → 498
    assert_equal 66.0,  r[0, 0]
    assert_equal 498.0, r[1, 1]
  end

  # ---- reduce_slab fiber form multi-axis

  def test_reduce_slab_fiber_inject_multi_axis
    a = CArray.float64(2, 3, 4).seq!
    r = a.reduce_slab(axis: [1, 2], init: 0.0) { |acc, x| acc + x }
    assert_equal [66.0, 210.0], r.to_a
  end

  # ---- non-contig multi-axis (= β.xc' Piece B: own gather/scatter scratch)

  def test_reduce_slab_non_innermost_multi_axis
    # axis: [0, 1] = non-innermost → slab is non-contig in src memory.
    # Own-scratch K-D gather makes this work.
    a = CArray.float64(2, 3, 4).seq!
    r = a.reduce_slab(axis: [0, 1]) { |slab| slab.sum }
    # slab j: cells (i, k, j) for i ∈ 0..1, k ∈ 0..2.  In seq, cell value
    # = 12i + 4k + j.  Sum = 12*1*3 + 4*3*2 + 6j = 36 + 24 + 6j = 60 + 6j.
    assert_equal [60.0, 66.0, 72.0, 78.0], r.to_a
  end

  def test_reduce_slab_non_contig_axis_0_and_2
    a = CArray.float64(2, 3, 4).seq!
    r = a.reduce_slab(axis: [0, 2]) { |slab| slab.sum }
    # slab k: cells (i, k, j) for i ∈ 0..1, j ∈ 0..3.
    # Sum = 12*1*4 + 4k*2*4 + 6*2 = 48 + 32k + 12 = 60 + 32k.
    assert_equal [60.0, 92.0, 124.0], r.to_a
  end

  def test_each_slab_non_contig_multi_axis
    a = CArray.float64(2, 3, 4).seq!
    seen_sums = []
    a.each_slab(axis: [0, 2]) { |slab| seen_sums << slab.sum }
    assert_equal [60.0, 92.0, 124.0], seen_sums
  end

  # ---- map_slab multi-axis (= β.xc' Piece A contig + Piece B non-contig)

  def test_map_slab_multi_axis_contig_innermost_K
    a = CArray.float64(2, 3, 4).seq!
    out = a.map_slab(axis: [1, 2]) { |slab| slab + 100 }
    # Output shape = src shape; cell (i,k,j) = a(i,k,j) + 100
    assert_equal a.dim.to_a, out.dim.to_a
    assert_equal [100.0, 101.0, 102.0, 103.0], out[0, 0, nil].to_a
    assert_equal [120.0, 121.0, 122.0, 123.0], out[1, 2, nil].to_a
  end

  def test_map_slab_multi_axis_non_contig_scatter
    a = CArray.float64(2, 3, 4).seq!
    out = a.map_slab(axis: [0, 2]) { |slab| slab + 100 }
    # slab at outer k yields cells (i, k, j); transform = +100.
    # Scatter back to output preserves the cell positions.
    (0...2).each do |i|
      (0...3).each do |k|
        (0...4).each do |j|
          assert_in_delta(a[i, k, j] + 100, out[i, k, j], 1e-9,
                          "non-contig scatter mismatch at #{[i,k,j]}")
        end
      end
    end
  end

  def test_map_slab_multi_axis_non_contig_scalar_broadcast
    a = CArray.float64(2, 3, 4).seq!
    out = a.map_slab(axis: [0, 2]) { |slab| slab.sum }
    # Slab k's sum (= 60 + 32k) broadcast over slab cells.
    # All cells in slab k = (any i, k, any j) should equal that sum.
    (0...3).each do |k|
      expected = 60.0 + 32.0 * k
      assert_equal expected, out[0, k, 0]
      assert_equal expected, out[1, k, 3]
    end
  end

  def test_map_slab_multi_axis_non_contig_data_type_cast
    a = CArray.float64(2, 3, 4).seq!
    out = a.map_slab(axis: [0, 2], data_type: :int32) { |slab| (slab + 100.5) }
    assert_equal :int32, out.data_type_name.to_sym
    # Cast-on-scatter via per-cell obj2ptr (= slow path); content correctness.
    (0...2).each do |i|
      (0...3).each do |k|
        (0...4).each do |j|
          assert_equal((a[i,k,j] + 100.5).to_i, out[i, k, j])
        end
      end
    end
  end

  def test_reduce_slab_non_contig_mask_carry
    a = CArray.float64(2, 3, 4).seq!
    a[0, 1, 2] = UNDEF                   # value 6.0 masked
    r = a.reduce_slab(axis: [0, 1]) { |slab| slab.sum }
    # slab j=2 lost cell (0,1,2) value=6, so 72 → 66; others unchanged.
    assert_equal [60.0, 66.0, 66.0, 78.0], r.to_a
  end

  def test_map_slab_non_contig_mask_input_visible
    a = CArray.float64(2, 3, 4).seq!
    a[0, 1, 2] = UNDEF
    mask_counts = []
    a.map_slab(axis: [0, 2]) do |slab|
      mask_counts << slab.count_masked
      slab.sum
    end
    # slab k=1 contains (0,1,2) → 1 masked cell; others 0.
    assert_equal [0, 1, 0], mask_counts
  end

  # ---- mask transparent carry on multi-axis

  def test_each_slab_multi_axis_mask_carry
    a = CArray.float64(2, 3, 4).seq!
    a[0, 1, 2] = UNDEF
    seen_mask_counts = []
    a.each_slab(axis: [1, 2]) do |slab|
      assert slab.has_mask?
      seen_mask_counts << slab.count_masked
    end
    assert_equal [1, 0], seen_mask_counts
  end

  def test_reduce_slab_multi_axis_mask_honored
    a = CArray.float64(2, 3, 4).seq!
    a[0, 1, 2] = UNDEF      # value would have been 6.0
    r = a.reduce_slab(axis: [1, 2]) { |slab| slab.sum }
    # slab 0 unmasked sum = 66 - 6 = 60; slab 1 sum = 210
    assert_equal [60.0, 210.0], r.to_a
  end

  def test_reduce_slab_fiber_multi_axis_yields_UNDEF
    a = CArray.float64(2, 2, 3).seq!
    a[0, 0, 1] = UNDEF
    seen_undef = false
    a.reduce_slab(axis: [1, 2], init: 0.0) do |acc, x|
      seen_undef = true if x.equal?(UNDEF)
      x.equal?(UNDEF) ? acc : acc + x
    end
    assert seen_undef, "fiber form must yield CA::UNDEF for masked elements"
  end

  # ---- argument errors

  def test_axis_array_with_duplicate_raises
    a = CArray.float64(2, 3, 4).seq!
    assert_raise(ArgumentError) do
      a.each_slab(axis: [1, 1]) { |slab| }
    end
  end

  def test_axis_array_with_out_of_range_raises
    a = CArray.float64(2, 3, 4).seq!
    assert_raise(ArgumentError) do
      a.each_slab(axis: [1, 99]) { |slab| }
    end
  end

  # ---- Enumerator support for multi-axis

  def test_each_slab_multi_axis_enumerator
    a = CArray.float64(2, 3, 4).seq!
    sums = a.each_slab(axis: [1, 2]).map { |slab| slab.sum }
    assert_equal [66.0, 210.0], sums
  end
end

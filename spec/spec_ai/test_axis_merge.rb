# PROPOSAL_AXIS_MERGE Phase 1 (CAStride 0a) — pin strided-copy behavior
# across the 4 ca_stride_xfer_with_layout callers and the
# ca_stride_func_fill_data path BEFORE axis-merge is introduced, then
# verify they continue to produce binary-identical results AFTER.
#
# The merge transformation must preserve:
#   - read values (gather direction: to_ca, copy_data)
#   - write values (scatter direction: sync_data via [] =, attach! block)
#   - fill semantics (fill_data via [nil] = scalar)
#   - mask propagation (data + mask both merge-folded consistently)
#
# Tests are organised by:
#   (a) shapes that DO benefit from merge (= contig-mergeable axes)
#   (b) shapes that DON'T benefit (= non-contig boundaries; no-regression)
#   (c) edge cases: dim==1, stride==0 (CARepeat), negative stride

require "test/unit"
require "carray"

class TestAxisMergeBehavior < Test::Unit::TestCase

  # ===== (a) Shapes that merge =====
  # mid_axis_3d: a[:, lo:hi, :] has strides (outer, stride==dim*bytes, bytes)
  # where inner two axes are contig-mergeable.

  def test_mid_axis_3d_to_ca
    a = CArray.float64(20, 30, 10).seq
    view = a[nil, 5..14, nil]
    # Expected: each "row" of inner 100 elements is contig in entity
    mat = view.to_ca
    assert_equal [20, 10, 10], mat.dim
    assert_equal view.elements, mat.elements
    # Spot check a few cells
    assert_equal a[0, 5, 0], mat[0, 0, 0]
    assert_equal a[0, 5, 9], mat[0, 0, 9]
    assert_equal a[0, 14, 9], mat[0, 9, 9]
    assert_equal a[19, 14, 9], mat[19, 9, 9]
  end

  def test_mid_axis_3d_write_through_propagates
    a = CArray.float64(20, 30, 10).seq
    view = a[nil, 5..14, nil]
    view[3, 4, 7] = -1.0    # entity[3, 9, 7]
    assert_equal(-1.0, a[3, 9, 7])
  end

  def test_mid_axis_3d_fill_scalar
    a = CArray.float64(10, 30, 10).seq
    view = a[nil, 5..14, nil]
    view[] = 99.0
    # All cells in the selected sub-region should be 99
    assert_equal 99.0, a[0, 5, 0]
    assert_equal 99.0, a[9, 14, 9]
    # Cells outside the selected sub-region untouched
    assert_equal a.seq[0, 0, 0], CArray.float64(10, 30, 10).seq[0, 0, 0]   # baseline
    a2 = CArray.float64(10, 30, 10).seq
    view2 = a2[nil, 5..14, nil]
    view2[] = 99.0
    assert_equal 0.0, a2[0, 0, 0]    # entity[0,0,0] outside view
    assert_equal 4.0, a2[0, 0, 4]    # outside
    assert_equal 45.0, a2[0, 4, 5]   # entity[0,4,5] outside view, = 4*10+5
  end

  def test_mid_axis_3d_attach_bang_roundtrip
    a = CArray.float64(10, 30, 10).seq
    view = a[nil, 5..14, nil]
    view.attach! do |inner|
      inner[0, 0, 0] = -42.0
    end
    assert_equal(-42.0, a[0, 5, 0])
  end

  # CABlock with fully-contig sub-region (all axes mergeable into one
  # single-stride run): exercises alias path and post-merge collapse.
  def test_fully_contig_subblock_to_ca
    a = CArray.float64(10, 20).seq
    sub = a[3..7, nil]   # rows 3..7 fully contig
    mat = sub.to_ca
    expected = (3*20...8*20).map(&:to_f)
    assert_equal expected, mat.to_a.flatten
  end

  def test_fully_contig_subblock_fill
    a = CArray.float64(10, 20).seq
    sub = a[3..7, nil]
    sub[] = -7.0
    (3..7).each do |i|
      (0..19).each do |j|
        assert_equal(-7.0, a[i, j])
      end
    end
    # Boundary preserved
    assert_equal 2.0*20, a[2, 0]
    assert_equal 8.0*20, a[8, 0]
  end

  # ===== (b) Shapes that DON'T merge (no-regression) =====
  # row_stride2: a[::2, :] strides (2*dim*bytes, bytes) — outer axis stride
  # leaves gap, axes NOT inter-axis contig.

  def test_row_stride2_to_ca
    a = CArray.float64(10, 20).seq
    view = a[(0..-1).step(2), nil]
    mat = view.to_ca
    assert_equal 5, view.dim[0]
    expected = [0, 2, 4, 6, 8].flat_map { |i| (i*20...(i+1)*20).map(&:to_f) }
    assert_equal expected, mat.to_a.flatten
  end

  def test_col_slice_to_ca
    a = CArray.float64(10, 20).seq
    view = a[nil, 5..9]
    mat = view.to_ca
    assert_equal [10, 5], view.dim
    expected = (0..9).flat_map { |i| (5..9).map { |j| i*20 + j }.map(&:to_f) }
    assert_equal expected, mat.to_a.flatten
  end

  def test_transpose_2d_to_ca
    a = CArray.float64(5, 7).seq
    t = a.transpose
    mat = t.to_ca
    assert_equal [7, 5], t.dim
    (0..6).each do |i|
      (0..4).each do |j|
        assert_equal a[j, i], mat[i, j]
      end
    end
  end

  def test_col_slice_write_through
    a = CArray.float64(10, 20).seq
    view = a[nil, 5..9]
    view[3, 2] = -99.0   # entity[3, 7]
    assert_equal(-99.0, a[3, 7])
  end

  # ===== (c) Edge cases =====

  def test_dim1_axes_preserved
    a = CArray.float64(4, 1, 5).seq
    view = a[nil, nil, 1..3]   # dim (4, 1, 3)
    mat = view.to_ca
    assert_equal [4, 1, 3], mat.dim
    (0..3).each do |i|
      (1..3).each do |j|
        assert_equal a[i, 0, j], mat[i, 0, j-1]
      end
    end
  end

  def test_repeat_view_to_ca_unchanged
    # CARepeat introduces stride==0 axes; merge must not collapse them.
    a = CArray.int(1, 4).tap { |__a| __a[] = [10, 20, 30, 40] }
    rep = a.broadcast_to(3, 4)
    mat = rep.to_ca
    assert_equal [3, 4], mat.dim
    (0..2).each do |i|
      assert_equal [10, 20, 30, 40], mat[i, nil].to_a
    end
  end

  def test_as_strided_negative_inner_stride
    # Negative innermost stride: as_strided with reversed inner axis.
    a = CArray.float64(8).seq
    rev = a.as_strided(shape: [8], strides: [-8], offset: 7*8)
    mat = rev.to_ca
    assert_equal [7.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.0, 0.0], mat.to_a
  end

  def test_2d_as_strided_negative_outer_stride
    a = CArray.float64(4, 5).seq
    # Reverse outer axis: shape (4, 5), strides (-40, 8), offset = 3*40 = 120
    rev = a.as_strided(shape: [4, 5], strides: [-40, 8], offset: 120)
    mat = rev.to_ca
    (0..3).each do |i|
      (0..4).each do |j|
        assert_equal a[3 - i, j], mat[i, j]
      end
    end
  end

  # ===== (d) Mask propagation =====

  def test_mid_axis_3d_with_mask
    a = CArray.float64(10, 30, 10).seq
    a.mask = 0
    a[3, 8, 5] = UNDEF
    view = a[nil, 5..14, nil]
    mat = view.to_ca
    assert_true mat.has_mask?
    # entity[3,8,5] -> view[3, 3, 5]
    assert_equal UNDEF, mat[3, 3, 5]
    assert_not_equal UNDEF, mat[3, 3, 4]
  end

  def test_mid_axis_3d_mask_write_through
    a = CArray.float64(10, 30, 10).seq
    a.mask = 0
    view = a[nil, 5..14, nil]
    view[3, 4, 7] = UNDEF      # entity[3, 9, 7]
    assert_equal true, a.is_masked[3, 9, 7]
    assert_equal false, a.is_masked[3, 9, 6]
  end

  def test_mid_axis_3d_fill_undef
    a = CArray.float64(10, 30, 10).seq
    a.mask = 0
    view = a[nil, 5..14, nil]
    view[] = UNDEF
    # All cells in the view region masked
    assert_equal true, a.is_masked[0, 5, 0]
    assert_equal true, a.is_masked[9, 14, 9]
    # Outside untouched
    assert_equal false, a.is_masked[0, 0, 0]
    assert_equal false, a.is_masked[9, 4, 9]
  end

  # ===== (e) Compose-fold interaction =====
  # Multi-level chain: block of block, reshape of block, etc.

  def test_block_of_block_to_ca
    a = CArray.float64(10, 20).seq
    outer = a[2..7, nil]      # (6, 20)
    inner = outer[1..4, 5..14]  # (4, 10)
    mat = inner.to_ca
    assert_equal [4, 10], mat.dim
    (0..3).each do |i|
      (0..9).each do |j|
        assert_equal a[3 + i, 5 + j], mat[i, j]
      end
    end
  end

  def test_reshape_then_to_ca_after_rewrite
    # PROPOSAL_RESHAPE_STRIDE_REWRITE already produces a CAStride for
    # representable reshapes.  Combined with axis-merge, this exercises
    # the longest compose-fold chain.
    a = CArray.float64(20, 30, 10).seq
    view = a[nil, 5..14, nil]
    flat = view.reshape(200, 10)   # representable: inner 100 axis
    mat = flat.to_ca
    assert_equal [200, 10], mat.dim
    assert_equal view.elements, mat.elements
    # Verify first row corresponds to a[0, 5, *]
    assert_equal a[0, 5, nil].to_a, mat[0, nil].to_a
  end
end

# clip/crop/paste organisation in 3.0:
#   1. CArray#clip / #clip! = value-clamp (NumPy np.clip equiv).
#      Renamed from the old `trim` / `trim!`; `trim` is gone.
#   2. CArray#paste / #crop = sub-region copy in/out.  Restored to core
#      (autoloaded) in 3.0; the brief stint in `lib/extras/crop_paste.rb`
#      ended when `__paste_block__` was promoted to the real `paste`.
#   3. `crop` preserves dst's OOB cells (matches the old C `ca_clip`).

require 'test/unit'
require 'carray'

class TestClipValueClamp < Test::Unit::TestCase

  def test_clip_both_bounds
    a = CA_INT([1, 5, 10, 15, 20])
    assert_equal [5, 5, 10, 15, 15], a.clip(5, 15).to_a
  end

  def test_clip_min_only
    # nil max -> one-sided clamp from below (dispatches to pmax kernel).
    a = CA_INT([1, 5, 10, 15, 20])
    assert_equal [5, 5, 10, 15, 20], a.clip(5, nil).to_a
  end

  def test_clip_max_only
    # nil min -> one-sided clamp from above (dispatches to pmin kernel).
    a = CA_INT([1, 5, 10, 15, 20])
    assert_equal [1, 5, 10, 10, 10], a.clip(nil, 10).to_a
  end

  def test_clip_bang_retired_3_0
    # `clip!` is retired per the view-by-default convention
    # (CLAUDE.md: view-counterpart のある bang 兄弟は廃止).  Canonical
    # in-place idiom: `a[] = a.clip(lo, hi)`.
    a = CA_INT([1, 5, 10, 15, 20])
    refute a.respond_to?(:clip!), "clip! should be retired in 3.0"
    a[] = a.clip(5, 15)
    assert_equal [5, 5, 10, 15, 15], a.to_a
  end

  def test_clip_with_fill_value
    # The optional `fill_value` 3rd arg is preserved (rendering sentinel
    # injection / mask insertion via fill_value=UNDEF).  Boundary
    # semantics: strict `x < min` OR `x > max` (= consistent with the
    # no-fill simple-clamp path).  Value 15 stays as 15 (was -1 in the
    # pre-3.0 `>= max` form).
    a = CA_INT([1, 5, 10, 15, 20])
    assert_equal [-1, 5, 10, 15, -1], a.clip(5, 15, -1).to_a
  end

  def test_clip_with_fill_value_one_sided
    a = CA_INT([1, 5, 10, 15, 20])
    assert_equal [-1, 5, 10, 15, 20], a.clip(5, nil, -1).to_a
    assert_equal [1, 5, 10, 15, -1],  a.clip(nil, 15, -1).to_a
  end

  def test_clip_with_fill_value_undef_inserts_mask
    # `fill_value = UNDEF` lets the indexer-assignment path create mask
    # cells for out-of-range entries — a CArray-specific workflow not
    # available in NumPy.
    a = CA_INT([1, 5, 10, 15, 20])
    r = a.clip(5, 15, UNDEF)
    assert_equal [UNDEF, 5, 10, 15, UNDEF], r.to_a
    assert_equal [true, false, false, false, true], r.mask.to_a
  end

  def test_clip_both_nil_raises
    a = CA_INT([1, 5, 10, 15, 20])
    assert_raise(ArgumentError) { a.clip(nil, nil) }
  end

  def test_clip_with_array_bounds
    # NEW capability via the underlying mkkernel triop: per-element
    # variable lo / hi.  Old hand-written clip rejected non-scalar
    # bounds.
    v = CA_FLOAT64([-2.0, 0.5, 1.0, 1.5, 3.0])
    lo = CA_FLOAT64([0.0, 0.0, 0.5, 1.0, 0.0])
    hi = CA_FLOAT64([1.0, 0.4, 1.0, 1.0, 2.0])
    assert_equal [0.0, 0.4, 1.0, 1.0, 2.0], v.clip(lo, hi).to_a
  end

  def test_clip_returns_fresh_copy
    a = CA_INT([1, 5, 10, 15, 20])
    b = a.clip(5, 15)
    refute_same a, b
    assert_equal [1, 5, 10, 15, 20], a.to_a
  end

  def test_float_clip
    a = CA_FLOAT64([0.0, 0.5, 1.0, 1.5, 2.0])
    assert_equal [0.5, 0.5, 1.0, 1.5, 1.5], a.clip(0.5, 1.5).to_a
  end
end

class TestTrimGoneIn3_0 < Test::Unit::TestCase

  def test_trim_method_removed
    a = CA_INT([1, 2, 3])
    refute a.respond_to?(:trim), "CArray#trim should be removed in 3.0"
    refute a.respond_to?(:trim!), "CArray#trim! should be removed in 3.0"
  end
end

class TestPasteInCore < Test::Unit::TestCase

  def test_paste_2d_in_bounds
    dst = CArray.int32(3, 3) { 0 }
    src = CA_INT32([[1, 2], [3, 4]])
    dst.paste([0, 1], src)
    assert_equal [[0, 1, 2], [0, 3, 4], [0, 0, 0]], dst.to_a
  end

  def test_paste_negative_offset_clips
    dst = CArray.int32(3, 3) { 0 }
    src = CA_INT32([[1, 2], [3, 4]])
    # Offset (-1,-1): only src[1,1]=4 lands in dst[0,0].
    dst.paste([-1, -1], src)
    assert_equal [[4, 0, 0], [0, 0, 0], [0, 0, 0]], dst.to_a
  end

  def test_paste_oob_drops_silently
    dst = CArray.int32(5, 5) { 9 }
    src = CArray.int32(3, 3) { 1 }
    # offset (3,3) makes src's right/bottom 2 cols/rows fall outside dst.
    dst.paste([3, 3], src)
    assert_equal [[9,9,9,9,9],[9,9,9,9,9],[9,9,9,9,9],
                  [9,9,9,1,1],[9,9,9,1,1]], dst.to_a
  end

  def test_paste_returns_self
    dst = CArray.int32(3, 3) { 0 }
    src = CA_INT32([[1, 2], [3, 4]])
    assert_same dst, dst.paste([0, 0], src)
  end

  def test_paste_size_mismatch_offset_argerror
    dst = CArray.int32(3, 3) { 0 }
    src = CA_INT32([[1, 2], [3, 4]])
    assert_raise(ArgumentError) { dst.paste([0], src) }
  end
end

class TestCropInCore < Test::Unit::TestCase

  def test_crop_2d_in_bounds
    src = CArray.int32(5, 5){|i, j| i * 10 + j}
    dst = CArray.int32(2, 2) { 0 }
    src.crop([1, 1], dst)
    assert_equal [[11, 12], [21, 22]], dst.to_a
  end

  def test_crop_returns_dst
    src = CArray.int32(5, 5){|i, j| i * 10 + j}
    dst = CArray.int32(2, 2) { 0 }
    assert_same dst, src.crop([1, 1], dst)
  end

  def test_crop_oob_preserves_dst_cells
    # Old C ca_clip semantics: dst cells where src is OOB are untouched.
    src = CA_INT32([10, 20])
    dst = CArray.int32(4) { -1 }
    src.crop([0], dst)
    assert_equal [10, 20, -1, -1], dst.to_a
  end

  def test_crop_oob_2d_preserves_dst_corner
    src = CArray.int32(5, 5).seq
    dst = CArray.int32(3, 3) { 7 }
    src.crop([3, 3], dst)
    # In-bound 2x2 from src (3,3)..(4,4) = [[18,19],[23,24]].
    # The third row/column corresponds to OOB src reads, dst preserved.
    assert_equal [[18, 19, 7], [23, 24, 7], [7, 7, 7]], dst.to_a
  end

  def test_crop_negative_offset_preserves_dst
    src = CA_INT32([10, 20, 30])
    dst = CArray.int32(4) { -1 }
    src.crop([-1], dst)
    # dst[0] reads src[-1] (OOB, preserved -1).  dst[1..3] reads src[0..2].
    assert_equal [-1, 10, 20, 30], dst.to_a
  end

  def test_crop_fully_oob_leaves_dst_intact
    src = CA_INT32([1, 2, 3])
    dst = CArray.int32(3) { 99 }
    src.crop([100], dst)
    assert_equal [99, 99, 99], dst.to_a
  end

  def test_crop_size_mismatch_offset_argerror
    src = CArray.int32(5, 5).seq
    dst = CArray.int32(2, 2) { 0 }
    assert_raise(ArgumentError) { src.crop([0], dst) }
  end
end

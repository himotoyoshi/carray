require 'carray'
require 'test/unit'

# PROPOSAL_XFER_PROTOCOL step 3 (fold_stride): sometimes-fold participants
# (CAWindow interior, CAGrid all-STRIDE / singleton-INDEX) collapse into the
# CAStride compose-fold chain instead of materialising the whole view.  This
# must be value-equivalent to the non-folded (descriptor / attach) path.
#
# We can't directly observe "did it fold" from Ruby, so we pin value parity:
# the folded result, the folded result wrapped in a further stride view, and
# write-back through the folded view must all match the ground truth.
class TestXferFoldStride < Test::Unit::TestCase

  def setup
    @a = CArray.int32(6, 5).seq
  end

  # ---- CAGrid: all-STRIDE axes (Range) fold ----

  def test_grid_all_stride_fold_read
    g = @a.grid(nil, 1..3)
    assert_equal CAGrid, g.class
    assert_equal @a[nil, 1..3].to_a, g.to_a
  end

  def test_grid_all_stride_fold_chain
    # stride view on top of a foldable grid: compose walks stride -> grid -> entity
    g = @a.grid(nil, 1..3)
    assert_equal @a[1..3, 1..2].to_a, g[1..3, 0..1].to_a
  end

  def test_grid_all_stride_fold_write
    b = CArray.int32(6, 5).seq
    b.grid(nil, 1..3)[nil] = -1
    assert_equal [0, -1, -1, -1, 4], b[0, nil].to_a
    assert_equal [10, -1, -1, -1, 14], b[2, nil].to_a
  end

  # ---- CAGrid: singleton-INDEX axis bakes into base, folds ----

  def test_grid_singleton_index_fold
    si = CArray.int(1).tap { |__a| __a[] = [3] }
    g = @a.grid(si, nil)
    assert_equal [@a[3, nil].to_a], g.to_a
  end

  def test_grid_singleton_index_fold_write
    b = CArray.int32(6, 5).seq
    si = CArray.int(1).tap { |__a| __a[] = [2] }
    b.grid(si, nil)[nil] = -1
    assert_equal [-1] * 5, b[2, nil].to_a
    assert_equal (5..9).to_a, b[1, nil].to_a   # untouched
  end

  # ---- CAGrid: multi-element INDEX declines fold (descriptor engine) ----

  def test_grid_multi_index_declines_still_correct
    idx = CArray.int(3).tap { |__a| __a[] = [0, 2, 4] }
    g = @a.grid(idx, nil)
    assert_equal [@a[0, nil].to_a, @a[2, nil].to_a, @a[4, nil].to_a], g.to_a
  end

  def test_grid_multi_index_write
    b = CArray.int32(6, 5).seq
    idx = CArray.int(3).tap { |__a| __a[] = [0, 2, 4] }
    b.grid(idx, nil)[nil] = -1
    assert_equal [-1] * 5, b[0, nil].to_a
    assert_equal [-1] * 5, b[4, nil].to_a
    assert_equal (5..9).to_a, b[1, nil].to_a   # untouched
  end

  # ---- CASelectAxis (CSA): singleton boolean selection folds ----

  def test_csa_singleton_fold
    m = CArray.boolean(6) { 0 }; m[3] = 1
    cs = @a[m, nil]
    assert_equal CASelectAxis, cs.class
    assert_equal [@a[3, nil].to_a], cs.to_a
  end

  def test_csa_singleton_fold_chain
    m = CArray.boolean(6) { 0 }; m[3] = 1
    cs = @a[m, nil]
    assert_equal @a[3, 1..3].to_a, cs[0, 1..3].to_a
  end

  def test_csa_singleton_fold_write
    b = CArray.int32(6, 5).seq
    mb = CArray.boolean(6) { 0 }; mb[2] = 1
    b[mb, nil] = -1
    assert_equal [-1] * 5, b[2, nil].to_a
    assert_equal (5..9).to_a, b[1, nil].to_a   # untouched
  end

  def test_csa_multi_select_declines_still_correct
    m = CArray.boolean(6) { 0 }; m[0] = 1; m[2] = 1; m[4] = 1
    cs = @a[m, nil]
    assert_equal [@a[0, nil].to_a, @a[2, nil].to_a, @a[4, nil].to_a], cs.to_a
  end

  # ---- CAWindow interior folds (moved into fold_stride at step 3a) ----

  def test_window_interior_fold
    a = CArray.int32(10, 10).seq
    w = a.window(2..7, 3..8)
    assert_equal a[2..7, 3..8].to_a, w.to_a
    # wrapped: stride -> window(fold) -> entity
    assert_equal a[3..5, 5..7].to_a, w[1..3, 2..4].to_a
  end

  def test_window_boundary_declines_still_correct
    a = CArray.int32(8).seq
    w = a.window(-2..5, bounds: "fill")   # OOB at start -> boundary, declines fold
    ref = w.to_ca
    assert_equal ref.reshape(2, 4).to_a, w.reshape(2, 4).to_a
  end

  # ---- partial materialise wiring (step 3b): a CAStride leaf over a cold
  #      boundary view with an xfer_stride slot (CASelect / CAFake / CAByteSwap)
  #      delivers only its region, not the whole boundary. ----

  def test_partial_through_caselect_read
    big = CArray.int32(20).seq
    m = CArray.boolean(20) { 0 }; [2, 5, 8, 11, 14, 17].each { |i| m[i] = 1 }
    sel = big[m]                 # CASelect: [2,5,8,11,14,17]
    assert_equal [5, 8, 11], sel[1..3].to_a   # CAStride over CASelect (copy_data)
  end

  def test_partial_through_caselect_write
    b = CArray.int32(20).seq
    m = CArray.boolean(20) { 0 }; [2, 5, 8, 11, 14, 17].each { |i| m[i] = 1 }
    b[m][1..3] = -1              # sync_data through CASelect boundary
    assert_equal(-1, b[5]); assert_equal(-1, b[8]); assert_equal(-1, b[11])
    assert_equal 2, b[2]        # untouched
  end

  def test_partial_through_cafake_read
    big = CArray.int32(20).seq
    f = big.as_type(:float64)    # CAFake
    assert_equal [5.0, 6.0, 7.0, 8.0], f[5..8].to_a
  end

  def test_partial_through_cafake_write
    b = CArray.int32(20).seq
    b.as_type(:float64)[5..8] = 99.0
    assert_equal 99, b[5]; assert_equal 99, b[8]
    assert_equal 4, b[4]        # untouched
  end

  def test_partial_through_cabyteswap_roundtrip
    b = CArray.uint16(8).seq + 1
    assert_equal b[2..5].to_a, b.swap_bytes.swap_bytes[2..5].to_a
  end

  # ---- structural xfer_stride through a multi-INDEX CAGrid boundary
  #      (iterate INDEX axes, deliver inner run; declines fold). ----

  def test_partial_through_cagrid_outer_index
    a = CArray.int32(10, 10).seq
    idx = CArray.int(3).tap { |__a| __a[] = [1, 5, 8] }
    g = a.grid(idx, nil)         # axis0 multi-INDEX -> declines fold -> boundary
    assert_equal [[12, 13, 14], [52, 53, 54], [82, 83, 84]], g[nil, 2..4].to_a
  end

  def test_partial_through_cagrid_inner_index
    a = CArray.int32(10, 10).seq
    idx = CArray.int(3).tap { |__a| __a[] = [1, 5, 8] }
    g = a.grid(nil, idx)         # axis1 multi-INDEX (inner) -> xfer_addrs gather
    assert_equal((3..5).map { |r| [a[r, 1], a[r, 5], a[r, 8]] }, g[3..5, nil].to_a)
  end

  def test_partial_through_cagrid_write
    b = CArray.int32(10, 10).seq
    idx = CArray.int(3).tap { |__a| __a[] = [1, 5, 8] }
    b.grid(idx, nil)[nil, 2..4] = -1
    assert_equal(-1, b[1, 2]); assert_equal(-1, b[5, 4]); assert_equal(-1, b[8, 3])
    assert_equal 11, b[1, 1]   # untouched
  end

  def test_grid_all_stride_write_folds_not_xfer_stride
    # grid(nil,nil) is all-STRIDE -> folds; must NOT take the xfer_stride path.
    c = CArray.int(4, 3).seq
    c.grid(nil, nil)[nil] = CArray.int(4, 3).seq * -1
    assert_equal [[0, -1, -2], [-3, -4, -5], [-6, -7, -8], [-9, -10, -11]], c.to_a
  end

  def test_reshape_over_grid_ndim_mismatch_falls_back
    # flatten over a 2-D grid: request ndim != grid ndim -> bulk fallback, correct.
    d = CArray.int(4, 3).seq
    g = d.grid(CArray.int(2).tap { |__a| __a[] = [0, 2] }, nil)   # 2x3
    assert_equal [0, 1, 2, 6, 7, 8], g.flatten.to_a
  end

  # ---- structural xfer_stride through a multi-select CSA boundary ----

  def test_partial_through_csa_outer
    a = CArray.int32(10, 10).seq
    m = CArray.boolean(10) { 0 }; [1, 5, 8].each { |i| m[i] = 1 }
    assert_equal [[12, 13, 14], [52, 53, 54], [82, 83, 84]], a[m, nil][nil, 2..4].to_a
  end

  def test_partial_through_csa_inner
    a = CArray.int32(10, 10).seq
    m = CArray.boolean(10) { 0 }; [1, 5, 8].each { |i| m[i] = 1 }
    assert_equal((3..5).map { |r| [a[r, 1], a[r, 5], a[r, 8]] }, a[nil, m][3..5, nil].to_a)
  end

  def test_partial_through_csa_write
    b = CArray.int32(10, 10).seq
    m = CArray.boolean(10) { 0 }; [1, 5, 8].each { |i| m[i] = 1 }
    b[m, nil][nil, 2..4] = -1
    assert_equal(-1, b[1, 2]); assert_equal(-1, b[5, 4]); assert_equal(-1, b[8, 3])
    assert_equal 11, b[1, 1]
  end

  # ---- structural xfer_stride through a boundary-crossing CAWindow
  #      (OOB fill + in-bound region via parent.xfer_stride; declines fold). ----

  def test_partial_through_cawindow_1d
    a = CArray.int32(8).seq
    w = a.window(-2..9, fill_value: -1)   # 12 cells, OOB edges filled -1
    assert_equal [-1, -1, 0, 1, 2, 3, 4, 5, 6, 7, -1, -1], w.to_a
    assert_equal [-1, 0, 1, 2, 3, 4, 5, 6, 7, -1], w[1..10].to_a
  end

  def test_partial_through_cawindow_2d
    b = CArray.int32(5, 5).seq
    w = b.window(-1..5, -1..5, fill_value: -9)   # 7x7, edges OOB
    assert_equal b[1..3, 1..3].to_a, w[2..4, 2..4].to_a
  end

  def test_partial_through_cawindow_write
    c = CArray.int32(8).seq
    c.window(-2..9, fill_value: -1)[nil] = 100   # in-bound -> parent, OOB skipped
    assert_equal [100] * 8, c.to_a
  end

  def test_partial_through_cashift_boundary
    # CAShift inherits CAWindow's xfer_stride (ca_shift_func copy)
    a = CArray.int32(6).seq
    s = a.shift(2)               # OOB fill at start
    ref = s.to_ca
    assert_equal ref[1..4].to_a, s[1..4].to_a
  end

  # ---- per-cell bit transforms (CABitarray) deliver via the xfer_addrs path
  #      (no STRIDE structure to preserve). ----

  def test_partial_through_cabitarray_read
    u = CArray.uint8(8).seq
    ba = u.bits                  # boolean view [8,8]
    assert_equal ba.to_ca[2..4, nil].to_a, ba[2..4, nil].to_a
  end

  def test_partial_through_cabitarray_write
    v = CArray.uint8(4); 4.times { |i| v[i] = 0 }
    v.bits[1..2, nil] = 1        # set all bits of bytes 1,2 via slice
    assert_equal 0, v[0]
    assert_equal 0xFF, v[1]
    assert_equal 0xFF, v[2]
    assert_equal 0, v[3]
  end

  # ---- structural xfer_stride through CATile (modulo) / CARoll (shift) ----

  def test_partial_through_catile_read
    a = CArray.int32(3).seq
    assert_equal [2, 0, 1, 2, 0], a.tile(3)[2..6].to_a   # wraps tile boundary
  end

  def test_partial_through_catile_2d
    b = CArray.int32(2, 2).seq
    assert_equal [[3, 2], [1, 0]], b.tile(2, 2)[1..2, 1..2].to_a
  end

  def test_partial_through_catile_write
    t = CArray.int32(3).seq
    t.tile(2)[0..2] = CArray.int32(3).seq + 10
    assert_equal [10, 11, 12], t.to_a
  end

  def test_partial_through_caroll_read
    a = CArray.int32(6).seq
    assert_equal [5, 0, 1, 2], a.roll(2)[1..4].to_a
  end

  def test_partial_through_caroll_write
    b = CArray.int32(6).seq
    b.roll(2)[1..4] = 100        # view 1..4 -> parent 5,0,1,2
    assert_equal [100, 100, 100, 3, 4, 100], b.to_a
  end

  # ---- stride-family xfer_stride reached via a transform parent's recursion:
  #      CAFake over a stride chain -> CAFake.xfer_stride recurses
  #      parent.xfer_stride (ca_stride_func_xfer_stride), which composes the
  #      chain to its root once and delivers (vs the per-cell fallback). ----

  def test_stride_xfer_stride_via_cafake_over_transpose_read
    b = CArray.int32(4, 5).seq
    ft = b.transpose.as_type(:float64)   # CAFake(CATranspose(entity))
    expect = b.transpose[1..3, 0..2].to_a.map { |r| r.map(&:to_f) }
    assert_equal expect, ft[1..3, 0..2].to_a
  end

  def test_stride_xfer_stride_via_cafake_over_transpose_write
    c = CArray.int32(4, 5).seq
    c.transpose.as_type(:float64)[1..3, 0..2] = 99.0
    assert_equal 99, c.transpose[1, 0]
    assert_equal 99, c.transpose[3, 2]
    assert_equal 0, c.transpose[0, 0]
  end
end

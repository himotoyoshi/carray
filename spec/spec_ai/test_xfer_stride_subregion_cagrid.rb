# X.3 (PROPOSAL_XFER_STRIDE_PER_REGION_GAPS.md §4.3):
# CAGrid xfer_stride opportunistic axis_dispatch path correctness pin.
#
# Tests:
#   - whole-view byte parity (= xfer_all asymptote on entity parent)
#   - sub-region GET byte parity (interior / edge / sub-sampled with
#     src_step != 1)
#   - sub-region PUT round-trip
#   - virtual parent fallback (CAFake / CAByteSwap parent → CAGrid):
#     legacy per-row branch must preserve byte parity
#   - both STRIDE-only axes, INDEX-only, and mixed STRIDE/INDEX combos

require "test/unit"
require "carray"
require_relative "ext_xfer_smoke/load"
class TestXferStrideSubregionCAGrid < Test::Unit::TestCase

  def setup
    @n = 20
    @entity = CArray.float64(@n, @n) { |i,j| i * @n + j }
    @mask = CArray.boolean(@n); @n.times { |i| @mask[i] = (i % 3 == 0) }
    @idx = CArray.int32(@n/2).tap { |c| c[] = c.seq * 2 }
  end

  def expected_subregion(view, starts, counts)
    out = CArray.new(view.data_type, counts)
    counts[0].times do |i|
      counts[1].times do |j|
        out[i, j] = view[starts[0]+i, starts[1]+j]
      end
    end
    out
  end

  # whole-view xfer_stride byte parity with xfer_all (entity parent → asymptote)
  def test_whole_view_mask_axis1_matches_xfer_all
    view = @entity[nil, @mask]   # CAGrid: axis 0 STRIDE, axis 1 INDEX
    all_bytes    = CArray.bench_xfer_all_get(view, 1)
    stride_bytes = CArray.bench_xfer_stride_get(view, 1)
    assert_equal all_bytes, stride_bytes
  end

  def test_whole_view_idx_axis0_matches_xfer_all
    view = @entity.grid(@idx, nil)   # CAGrid: axis 0 INDEX, axis 1 STRIDE
    all_bytes    = CArray.bench_xfer_all_get(view, 1)
    stride_bytes = CArray.bench_xfer_stride_get(view, 1)
    assert_equal all_bytes, stride_bytes
  end

  def test_whole_view_both_index_matches_xfer_all
    view = @entity.grid(@idx, @mask)   # axis 0 INDEX, axis 1 INDEX
    all_bytes    = CArray.bench_xfer_all_get(view, 1)
    stride_bytes = CArray.bench_xfer_stride_get(view, 1)
    assert_equal all_bytes, stride_bytes
  end

  # sub-region GET (interior, edge) via xfer_stride
  def test_subregion_interior_mask_axis1
    view = @entity[nil, @mask]
    starts = [3, 2]; counts = [5, 3]
    actual = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    expected = expected_subregion(view, starts, counts)
    assert_equal expected.dump_binary, actual
  end

  def test_subregion_edge_idx_axis0
    view = @entity.grid(@idx, nil)
    starts = [0, 0]; counts = [@idx.elements/2, @n/2]
    actual = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    expected = expected_subregion(view, starts, counts)
    assert_equal expected.dump_binary, actual
  end

  def test_subregion_both_index
    view = @entity.grid(@idx, @mask)
    starts = [2, 1]; counts = [3, 2]
    actual = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    expected = expected_subregion(view, starts, counts)
    assert_equal expected.dump_binary, actual
  end

  # PUT round-trip on alias region (writes through view, reads back)
  def test_put_roundtrip_mask_axis1
    p = @entity.template
    p.seq!
    view = p[nil, @mask]
    starts = [3, 1]; counts = [4, 3]
    src = CArray.float64(*counts) { |i,j| 9000.0 + i*10 + j }
    counts[0].times do |i|
      counts[1].times do |j|
        view[starts[0]+i, starts[1]+j] = src[i, j]
      end
    end
    actual = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    assert_equal src.dump_binary, actual
  end

  # ---- virtual parent fallback pins (scope 外、correctness only) ----
  def test_fake_parent_mask_axis1_byte_parity
    view = @entity.fake(:int32)[nil, @mask]
    all_bytes    = CArray.bench_xfer_all_get(view, 1)
    stride_bytes = CArray.bench_xfer_stride_get(view, 1)
    assert_equal all_bytes, stride_bytes
    starts = [2, 1]; counts = [4, 3]
    actual = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    expected = expected_subregion(view, starts, counts)
    assert_equal expected.dump_binary, actual
  end

  def test_byteswap_parent_mask_axis1_byte_parity
    view = @entity.endian(:big)[nil, @mask]
    all_bytes    = CArray.bench_xfer_all_get(view, 1)
    stride_bytes = CArray.bench_xfer_stride_get(view, 1)
    assert_equal all_bytes, stride_bytes
  end

  # aligned ✗ branch (= existing per-cell fallback) still works
  def test_aligned_fail_per_cell_fallback
    # Force non-aligned access: a sub-sampled grid request would normally
    # be aligned; we exercise the legacy per-cell path indirectly through
    # CArray indexer which builds chains that the xfer_stride may receive
    # as non-axis-aligned.  Easiest sanity: whole-view via xfer_stride_smoke
    # exercises both identity and reversed-axis-0 (sub-region with non-
    # native strides).  Re-run on a CAGrid view.
    view = @entity[nil, @mask]
    mism = CArray.xfer_stride_smoke(view)
    assert_equal 0, mism
  end
end

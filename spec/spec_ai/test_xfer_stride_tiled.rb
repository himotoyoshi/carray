require 'carray'
require 'test/unit'

# Cache-tiled transpose fast path in ca_xfer_stride_dispatch (2026-05-30):
# when slab merge fails because the innermost stride is non-contig AND
# ndim == 2 AND strides[0] == bytes (outer view axis is source-contig),
# the dispatcher takes a 32x32 tiled path with an L1-resident scratch and
# typed stores for bytes ∈ {1, 2, 4, 8}.  This pins correctness across
# byte widths + GET/PUT directions + the boundary tile partial sizes.
class TestXferStrideTiled < Test::Unit::TestCase

  # ---- GET direction: transpose-style gather --------------------------------

  def test_get_transpose_float64
    a = CArray.float64(8, 8).seq
    b = a.transpose.to_ca
    expected = (0...8).map { |i| (0...8).map { |j| (j * 8 + i).to_f } }
    assert_equal expected, b.to_a
  end

  def test_get_transpose_int32
    a = CArray.int32(8, 8).seq
    b = a.transpose.to_ca
    expected = (0...8).map { |i| (0...8).map { |j| j * 8 + i } }
    assert_equal expected, b.to_a
  end

  def test_get_transpose_int16
    a = CArray.int16(8, 8).tap { |x| x[] = x.seq + 100 }
    b = a.transpose.to_ca
    expected = (0...8).map { |i| (0...8).map { |j| j * 8 + i + 100 } }
    assert_equal expected, b.to_a
  end

  def test_get_transpose_int8
    a = CArray.int8(4, 4).tap { |x| x[] = x.seq }
    b = a.transpose.to_ca
    expected = [[0, 4, 8, 12], [1, 5, 9, 13], [2, 6, 10, 14], [3, 7, 11, 15]]
    assert_equal expected, b.to_a
  end

  # ---- partial tile at boundaries ------------------------------------------

  def test_get_transpose_partial_tile
    # 40x40 -> tiles at boundary need partial Tj/Ti handling (TILE=32).
    a = CArray.float64(40, 40).seq
    b = a.transpose.to_ca
    (0...40).each do |i|
      (0...40).each do |j|
        assert_equal a[j, i].to_f, b[i, j].to_f, "[#{i},#{j}]"
      end
    end
  end

  def test_get_transpose_through_fake
    # CAFake middle layer: triggers parent.xfer_stride with pstrides=[8, N*8]
    # (rescaled), which is exactly the tiled transpose entry condition.
    a = CArray.float64(16, 16).tap { |x| x[] = x.seq + 0.5 }
    b = a.fake(:int32).transpose.to_ca
    (0...16).each do |i|
      (0...16).each do |j|
        assert_equal a[j, i].to_i, b[i, j], "[#{i},#{j}]"
      end
    end
  end

  def test_get_transpose_through_swap_bytes
    a = CArray.int32(8, 8).seq
    raw = a.swap_bytes.transpose.to_ca
    direct = a.swap_bytes.to_ca   # full materialise via xfer_all path
    expected = (0...8).map { |i| (0...8).map { |j| direct[j, i] } }
    assert_equal expected, raw.to_a
  end

  # ---- PUT direction: write through transposed view -------------------------

  def test_put_transpose_float64
    a = CArray.float64(8, 8).seq
    a.transpose[] = CArray.float64(8, 8) { -1.0 }
    assert_equal [-1.0] * 64, a.flatten.to_a
  end

  def test_put_transpose_int32_partial_pattern
    a = CArray.int32(8, 8).seq
    src = CArray.int32(8, 8).tap { |x| x[] = x.seq + 100 }
    a.transpose[] = src
    # After: a[i,j] = src[j,i]
    (0...8).each do |i|
      (0...8).each do |j|
        assert_equal src[j, i], a[i, j], "[#{i},#{j}]"
      end
    end
  end

  # ---- rectangular (non-square) shape regression pin ------------------------

  def test_get_transpose_rectangular
    # Non-square trigger: tile loop must handle Ti != Tj at all boundary cells.
    a = CArray.float64(36, 20).seq
    b = a.transpose.to_ca     # shape (20, 36)
    assert_equal [20, 36], b.dim
    (0...20).each do |i|
      (0...36).each do |j|
        assert_equal a[j, i], b[i, j], "[#{i},#{j}]"
      end
    end
  end

  # ---- ndim >= 3 innermost-2-axis transpose-like (SPEC_XFER_STRIDE_NDIM_TILE)
  # These cases exercise the dispatcher's generalised tile branch (and
  # CAStride family's mirrored branch when reached through transform chains).
  # ndim == 2 cases above remain byte-equivalent via outer_n == 0 degenerate.

  def naive_transpose_to_a(a, perm)
    out_dim = perm.map { |k| a.dim[k] }
    out = CArray.float64(*out_dim)
    out.elements.times do |flat|
      out_idx = []
      rem = flat
      out_dim.reverse.each do |d|
        out_idx.unshift(rem % d); rem /= d
      end
      src_idx = Array.new(a.ndim)
      perm.each_with_index { |sk, dk| src_idx[sk] = out_idx[dk] }
      out[*out_idx] = a[*src_idx]
    end
    out.to_a
  end

  def test_get_transpose_ndim3_innermost_swap
    a = CArray.float64(4, 50, 30).seq
    b = a.transpose(0, 2, 1).to_ca
    assert_equal naive_transpose_to_a(a, [0, 2, 1]), b.to_a
  end

  def test_get_transpose_ndim3_int32
    a = CArray.int32(3, 40, 25).tap { |x| x[] = x.seq }
    b = a.transpose(0, 2, 1).to_ca
    assert_equal b.dim, [3, 25, 40]
    3.times { |i| 25.times { |j| 40.times { |k|
      assert_equal a[i, k, j], b[i, j, k]
    }}}
  end

  def test_get_transpose_ndim4_meteorology_lat_lon_swap
    # (time=2, level=3, lat=20, lon=15) -> (2, 3, 15, 20)
    a = CArray.float64(2, 3, 20, 15).seq
    b = a.transpose(0, 1, 3, 2).to_ca
    assert_equal [2, 3, 15, 20], b.dim
    2.times { |t| 3.times { |l| 15.times { |lo| 20.times { |la|
      assert_equal a[t, l, la, lo], b[t, l, lo, la], "[#{t},#{l},#{lo},#{la}]"
    }}}}
  end

  def test_get_transpose_ndim5_sanity
    # 5-D innermost-2-axis swap. Verifies dispatcher generalisation does not
    # crash and returns correct values at a few sample points.
    a = CArray.float64(2, 2, 3, 8, 6).seq
    b = a.transpose(0, 1, 2, 4, 3).to_ca
    assert_equal [2, 2, 3, 6, 8], b.dim
    # idx for source (2,2,3,8,6): axes 0..4 with sizes 2,2,3,8,6
    [[0,0,0,0,0], [1,1,2,7,5], [0,1,1,3,4]].each do |idx|
      out_idx = [idx[0], idx[1], idx[2], idx[4], idx[3]]
      assert_equal a[*idx], b[*out_idx]
    end
  end

  def test_put_transpose_ndim3
    # Write into a transposed view; expect parent storage to receive values
    # at the permuted positions.
    parent = CArray.float64(2, 5, 4).seq
    view = parent.transpose(0, 2, 1)            # view shape (2, 4, 5)
    src = CArray.float64(2, 4, 5).tap { |x| x[] = -x.seq - 1 }
    view[] = src
    # Verify: parent[i, k, j] should now equal src[i, j, k]
    2.times { |i| 4.times { |j| 5.times { |k|
      assert_equal src[i, j, k], parent[i, k, j], "[#{i},#{k},#{j}]"
    }}}
  end

  def test_get_chain_byteswap_of_transpose_ndim3
    # CAByteSwap wrapping a transposed view -> endian(:big).to_ca cascades
    # through the transform chain.  Values must round-trip when re-byteswapped.
    a = CArray.int32(3, 40, 25).tap { |x| x[] = x.seq }
    swapped = a.transpose(0, 2, 1).endian(:big).to_ca   # int32 BE bytes
    # round-trip back to native int32 to verify values
    roundtrip = swapped.endian(:big).to_ca
    3.times { |i| 25.times { |j| 40.times { |k|
      assert_equal a[i, k, j], roundtrip[i, j, k]
    }}}
  end

  def test_get_degenerate_ndim3_inner_count1
    # Degenerate counts[ndim-1] == 1: transpose of (4, 8, 1) view.
    # The tile branch should still produce correct results (or fall through).
    a = CArray.float64(4, 8, 1).seq
    b = a.transpose(0, 2, 1).to_ca
    assert_equal [4, 1, 8], b.dim
    4.times { |i| 8.times { |k|
      assert_equal a[i, k, 0], b[i, 0, k]
    }}
  end

  def test_get_data_type_boundary_16byte_cmplx128
    # ca->bytes == 16 (cmplx128) is the threshold: tile branch fires.
    # Verify result correctness; performance is incidental here.
    a = CArray.cmplx128(3, 10, 8).tap { |x| x[] = x.seq + Complex(0, 1) * x.seq }
    b = a.transpose(0, 2, 1).to_ca
    3.times { |i| 8.times { |j| 10.times { |k|
      assert_equal a[i, k, j], b[i, j, k]
    }}}
  end
end

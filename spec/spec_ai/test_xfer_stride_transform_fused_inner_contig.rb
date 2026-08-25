# X.4 (PROPOSAL_XFER_STRIDE_PER_REGION_GAPS.md §4.4):
# transform-fused inner-contig fast path correctness pin.
#
# Tests:
#   - whole-view CAFake / CAByteSwap byte parity vs xfer_all
#   - sub-region row-major byte parity (= inner-contig path triggers)
#   - A spelling preservation (= CATranspose-of-CAFake transposed inner,
#     inner_stride != parent_bytes → falls through to existing path)
#   - PUT round-trip in both fast and slow paths

require "test/unit"
require "carray"
require_relative "ext_xfer_smoke/load"
class TestXferStrideTransformFusedInnerContig < Test::Unit::TestCase

  def setup
    @n = 20
    @entity = CArray.float64(@n, @n).seq
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

  # ---- whole-view fast path (inner-contig triggers) ----
  def test_cafake_whole_view_matches_xfer_all
    view = @entity.fake(:int32)
    a = CArray.bench_xfer_all_get(view, 1)
    s = CArray.bench_xfer_stride_get(view, 1)
    assert_equal a, s
  end

  def test_cabyteswap_whole_view_matches_xfer_all
    view = @entity.endian(:big)
    a = CArray.bench_xfer_all_get(view, 1)
    s = CArray.bench_xfer_stride_get(view, 1)
    assert_equal a, s
  end

  # ---- sub-region row-major (inner-contig path) ----
  def test_cafake_subregion_interior_byte_parity
    view = @entity.fake(:int32)
    starts = [4, 5]; counts = [6, 7]
    actual = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    expected = expected_subregion(view, starts, counts)
    assert_equal expected.dump_binary, actual
  end

  def test_cabyteswap_subregion_interior_byte_parity
    view = @entity.endian(:big)
    starts = [3, 2]; counts = [5, 8]
    actual = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    expected = expected_subregion(view, starts, counts)
    assert_equal expected.dump_binary, actual
  end

  def test_cafake_subregion_edge_byte_parity
    view = @entity.fake(:int32)
    starts = [0, 0]; counts = [@n/2, @n/2]
    actual = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    expected = expected_subregion(view, starts, counts)
    assert_equal expected.dump_binary, actual
  end

  # ---- A spelling preservation (inner_stride != parent_bytes path) ----
  # These chains route through CATranspose.xfer_stride which then calls
  # the parent (CAFake / CAByteSwap) xfer_stride with TRANSPOSED inner
  # strides.  The X.4 gate (inner_stride == parent_bytes) is FALSE in
  # this case, so the existing scratch+gather path runs — preserving
  # the 2026-05-31 A spelling regression fix.
  def test_a_spelling_fake_transpose_byte_parity
    view = @entity.fake(:int32).transpose
    a = CArray.bench_xfer_all_get(view, 1)
    s = CArray.bench_xfer_stride_get(view, 1)
    assert_equal a, s
  end

  def test_a_spelling_transpose_fake_byte_parity
    view = @entity.transpose.fake(:int32)
    a = CArray.bench_xfer_all_get(view, 1)
    s = CArray.bench_xfer_stride_get(view, 1)
    assert_equal a, s
  end

  def test_a_spelling_endian_transpose_byte_parity
    view = @entity.endian(:big).transpose
    a = CArray.bench_xfer_all_get(view, 1)
    s = CArray.bench_xfer_stride_get(view, 1)
    assert_equal a, s
  end

  def test_a_spelling_transpose_endian_byte_parity
    view = @entity.transpose.endian(:big)
    a = CArray.bench_xfer_all_get(view, 1)
    s = CArray.bench_xfer_stride_get(view, 1)
    assert_equal a, s
  end

  # End-to-end .to_ca through A spelling chains (= materialise via xfer_all,
  # which delegates to xfer_stride for CAStride family parent)
  def test_a_spelling_to_ca_value_parity
    expected = CArray.float64(@n, @n).seq
    [
      expected.fake(:int32).transpose,
      expected.transpose.fake(:int32),
      expected.endian(:big).transpose,
      expected.transpose.endian(:big),
    ].each do |view|
      mat = view.to_ca
      assert_equal view.dim, mat.dim
      view.dim[0].times do |i|
        view.dim[1].times do |j|
          assert_equal view[i, j], mat[i, j]
        end
      end
    end
  end

  # ---- PUT round-trip in fast path ----
  def test_cafake_put_subregion_roundtrip
    p = @entity.template
    p.seq!
    view = p.fake(:int32)
    starts = [3, 2]; counts = [4, 5]
    src = CArray.int32(*counts).seq * -1
    counts[0].times do |i|
      counts[1].times do |j|
        view[starts[0]+i, starts[1]+j] = src[i, j]
      end
    end
    actual = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    assert_equal src.dump_binary, actual
  end

  def test_cabyteswap_put_subregion_roundtrip
    p = @entity.template
    p.seq!
    view = p.endian(:big)
    starts = [2, 1]; counts = [3, 4]
    src = CArray.float64(*counts).seq * -1.0
    counts[0].times do |i|
      counts[1].times do |j|
        view[starts[0]+i, starts[1]+j] = src[i, j]
      end
    end
    actual = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    assert_equal src.dump_binary, actual
  end

  # ---- xfer_stride_smoke (identity + reversed-axis-0) sanity ----
  def test_smoke_cafake
    assert_equal 0, CArray.xfer_stride_smoke(@entity.fake(:int32))
  end

  def test_smoke_cabyteswap
    assert_equal 0, CArray.xfer_stride_smoke(@entity.endian(:big))
  end

  def test_smoke_a_spelling
    assert_equal 0, CArray.xfer_stride_smoke(@entity.fake(:int32).transpose)
  end
end

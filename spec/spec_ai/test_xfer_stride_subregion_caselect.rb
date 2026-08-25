# X.6 (PROPOSAL_XFER_STRIDE_PER_REGION_GAPS.md §4.6):
# CASelect xfer_stride opportunistic path correctness pin (1-D INDEX
# over flat-parent, X.5 simplified).
#
# Tests:
#   - whole-view byte parity
#   - sub-region GET (interior / edge / tail)
#   - PUT round-trip (alias region only)
#   - virtual parent fallback (CAFake / CAByteSwap → CASelect)
#   - xfer_stride_smoke (identity + reversed step)

require "test/unit"
require "carray"
require_relative "ext_xfer_smoke/load"
class TestXferStrideSubregionCASelect < Test::Unit::TestCase

  def setup
    @n = 12
    @entity = CArray.float64(@n, @n).seq
    @mask   = CArray.boolean(@n, @n)
    (@n * @n).times { |i| @mask[i] = (i % 3 == 0) }
  end

  def expected_subregion(view, starts, counts)
    out = CArray.new(view.data_type, counts)
    counts[0].times do |i|
      out[i] = view[starts[0] + i]
    end
    out
  end

  # whole-view: xfer_stride byte-identical to xfer_all
  def test_whole_view_matches_xfer_all
    view = @entity[@mask]
    a = CArray.bench_xfer_all_get(view, 1)
    s = CArray.bench_xfer_stride_get(view, 1)
    assert_equal a, s
  end

  # sub-region: interior / edge / tail
  def test_subregion_interior
    view = @entity[@mask]
    n = view.elements
    starts = [n/4]; counts = [n/2]
    actual = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    expected = expected_subregion(view, starts, counts)
    assert_equal expected.dump_binary, actual
  end

  def test_subregion_edge
    view = @entity[@mask]
    n = view.elements
    starts = [0]; counts = [n/3]
    actual = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    expected = expected_subregion(view, starts, counts)
    assert_equal expected.dump_binary, actual
  end

  def test_subregion_tail
    view = @entity[@mask]
    n = view.elements
    starts = [n - n/3]; counts = [n/3]
    actual = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    expected = expected_subregion(view, starts, counts)
    assert_equal expected.dump_binary, actual
  end

  # PUT round-trip
  def test_put_subregion_roundtrip
    p = @entity.template; p.seq!
    view = p[@mask]
    n = view.elements
    starts = [n/4]; counts = [n/2]
    src = CArray.float64(*counts).seq * 1000.0
    counts[0].times do |i|
      view[starts[0] + i] = src[i]
    end
    actual = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    assert_equal src.dump_binary, actual
  end

  # virtual parent fallback (scope 外、correctness only)
  def test_fake_parent_byte_parity
    view = @entity.fake(:int32)[@mask]
    a = CArray.bench_xfer_all_get(view, 1)
    s = CArray.bench_xfer_stride_get(view, 1)
    assert_equal a, s
  end

  def test_byteswap_parent_byte_parity
    view = @entity.endian(:big)[@mask]
    a = CArray.bench_xfer_all_get(view, 1)
    s = CArray.bench_xfer_stride_get(view, 1)
    assert_equal a, s
  end

  # smoke: identity + reversed-axis-0 (= step != 1 case for X.6 fast path)
  def test_smoke_caselect
    assert_equal 0, CArray.xfer_stride_smoke(@entity[@mask])
  end
end

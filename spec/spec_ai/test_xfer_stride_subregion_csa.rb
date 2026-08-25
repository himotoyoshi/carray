# X.5 (PROPOSAL_XFER_STRIDE_PER_REGION_GAPS.md §4.5):
# CASelectAxis (CSA) xfer_stride opportunistic axis_dispatch path
# correctness pin.
#
# Tests:
#   - whole-view byte parity for 3 axis positions (outer / middle / inner)
#   - sub-region GET byte parity
#   - PUT round-trip
#   - virtual parent fallback byte parity (scope 外 = legacy path)

require "test/unit"
require "carray"
require_relative "ext_xfer_smoke/load"
class TestXferStrideSubregionCSA < Test::Unit::TestCase

  def setup
    @n = 12
    @entity = CArray.float64(@n, @n, @n).seq
    @mask   = CArray.boolean(@n); @n.times { |i| @mask[i] = (i % 3 == 0) }
  end

  def expected_subregion(view, starts, counts)
    out = CArray.new(view.data_type, counts)
    counts[0].times do |i|
      counts[1].times do |j|
        counts[2].times do |k|
          out[i, j, k] = view[starts[0]+i, starts[1]+j, starts[2]+k]
        end
      end
    end
    out
  end

  # whole-view: xfer_stride byte-identical to xfer_all (= entity parent
  # asymptote pin for all 3 axis positions)
  def test_whole_view_axis0_matches_xfer_all
    view = @entity[@mask, nil, nil]
    a = CArray.bench_xfer_all_get(view, 1)
    s = CArray.bench_xfer_stride_get(view, 1)
    assert_equal a, s
  end

  def test_whole_view_axis1_matches_xfer_all
    view = @entity[nil, @mask, nil]
    a = CArray.bench_xfer_all_get(view, 1)
    s = CArray.bench_xfer_stride_get(view, 1)
    assert_equal a, s
  end

  def test_whole_view_axis2_matches_xfer_all
    view = @entity[nil, nil, @mask]
    a = CArray.bench_xfer_all_get(view, 1)
    s = CArray.bench_xfer_stride_get(view, 1)
    assert_equal a, s
  end

  # sub-region GET: byte parity vs cell-by-cell expected
  def test_subregion_axis0_interior_byte_parity
    view = @entity[@mask, nil, nil]
    vd = view.dim
    starts = [1, 2, 3]; counts = [2, 5, 4]
    actual = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    expected = expected_subregion(view, starts, counts)
    assert_equal expected.dump_binary, actual
  end

  def test_subregion_axis1_interior_byte_parity
    view = @entity[nil, @mask, nil]
    starts = [2, 1, 3]; counts = [4, 2, 5]
    actual = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    expected = expected_subregion(view, starts, counts)
    assert_equal expected.dump_binary, actual
  end

  def test_subregion_axis2_interior_byte_parity
    view = @entity[nil, nil, @mask]
    starts = [2, 3, 1]; counts = [4, 5, 2]
    actual = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    expected = expected_subregion(view, starts, counts)
    assert_equal expected.dump_binary, actual
  end

  def test_subregion_edge_axis0
    view = @entity[@mask, nil, nil]
    starts = [0, 0, 0]; counts = [view.dim[0]/2, @n/2, @n/2]
    actual = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    expected = expected_subregion(view, starts, counts)
    assert_equal expected.dump_binary, actual
  end

  # PUT round-trip on sub-region
  def test_put_subregion_roundtrip_axis0
    p = @entity.template; p.seq!
    view = p[@mask, nil, nil]
    starts = [1, 2, 3]; counts = [2, 3, 4]
    src = CArray.float64(*counts).seq * 1000.0
    counts[0].times do |i|
      counts[1].times do |j|
        counts[2].times do |k|
          view[starts[0]+i, starts[1]+j, starts[2]+k] = src[i, j, k]
        end
      end
    end
    actual = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    assert_equal src.dump_binary, actual
  end

  def test_put_subregion_roundtrip_axis2
    p = @entity.template; p.seq!
    view = p[nil, nil, @mask]
    starts = [2, 3, 1]; counts = [3, 4, 2]
    src = CArray.float64(*counts).seq * -7.0
    counts[0].times do |i|
      counts[1].times do |j|
        counts[2].times do |k|
          view[starts[0]+i, starts[1]+j, starts[2]+k] = src[i, j, k]
        end
      end
    end
    actual = CArray.bench_xfer_stride_subregion_get(view, starts, counts, 1)
    assert_equal src.dump_binary, actual
  end

  # ---- Virtual parent fallback (scope 外、correctness only) ----
  def test_fake_parent_axis0_byte_parity
    view = @entity.fake(:int32)[@mask, nil, nil]
    a = CArray.bench_xfer_all_get(view, 1)
    s = CArray.bench_xfer_stride_get(view, 1)
    assert_equal a, s
  end

  def test_byteswap_parent_axis0_byte_parity
    view = @entity.endian(:big)[@mask, nil, nil]
    a = CArray.bench_xfer_all_get(view, 1)
    s = CArray.bench_xfer_stride_get(view, 1)
    assert_equal a, s
  end

  # ---- smoke (identity + reversed-axis-0) ----
  def test_smoke_csa_axis0
    assert_equal 0, CArray.xfer_stride_smoke(@entity[@mask, nil, nil])
  end

  def test_smoke_csa_axis1
    assert_equal 0, CArray.xfer_stride_smoke(@entity[nil, @mask, nil])
  end

  def test_smoke_csa_axis2
    assert_equal 0, CArray.xfer_stride_smoke(@entity[nil, nil, @mask])
  end
end

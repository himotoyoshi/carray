# Y.6 (PROPOSAL_XFER_ADDRS_PER_REGION_GAPS.md §4.6): CSA / CASelect
# producer-side STRIDE promotion.  When indices form a constant-step
# sequence (= consecutive TRUE block, all-TRUE, equally-spaced mask),
# describe_axes emits STRIDE kind instead of INDEX, unlocking engine's
# contig-memcpy fast path for STRIDE step=1.

require 'test/unit'
require 'carray'
require_relative "ext_xfer_smoke/load"
class TestY6SortedIndexStridePromotion < Test::Unit::TestCase

  # ---- CASelectAxis (CSA) descriptor promotion ----

  def test_csa_all_true_mask_promotes_to_stride
    omit "requires CARRAY_DEV_BUILD" unless CAGrid.method_defined?(:_describe_axes)
    a = CArray.int(10, 4).seq
    m = CArray.boolean(10).fill(1)
    desc = a[m, nil]._describe_axes
    # All-TRUE -> STRIDE(10, 0, 1)
    assert_equal [:stride, 10, 0, 1], desc[0]
  end

  def test_csa_consecutive_true_block_promotes_to_stride
    omit "requires CARRAY_DEV_BUILD" unless CAGrid.method_defined?(:_describe_axes)
    a = CArray.int(10, 4).seq
    m = CArray.boolean(10).tap { |__a| __a[] = [0, 0, 1, 1, 1, 1, 0, 0, 0, 0] }
    desc = a[m, nil]._describe_axes
    # Block [2..5] -> STRIDE(4, 2, 1)
    assert_equal [:stride, 4, 2, 1], desc[0]
  end

  def test_csa_equally_spaced_mask_promotes_to_stride
    omit "requires CARRAY_DEV_BUILD" unless CAGrid.method_defined?(:_describe_axes)
    a = CArray.int(10, 4).seq
    m = CArray.boolean(10).tap { |__a| __a[] = [1, 0, 1, 0, 1, 0, 1, 0, 1, 0] }
    desc = a[m, nil]._describe_axes
    # Every other -> STRIDE(5, 0, 2)
    assert_equal [:stride, 5, 0, 2], desc[0]
  end

  def test_csa_non_uniform_mask_keeps_index_kind
    omit "requires CARRAY_DEV_BUILD" unless CAGrid.method_defined?(:_describe_axes)
    a = CArray.int(10, 4).seq
    m = CArray.boolean(10).tap { |__a| __a[] = [1, 1, 0, 1, 0, 0, 1, 0, 0, 0] }
    desc = a[m, nil]._describe_axes
    # Indices [0,1,3,6] non-constant step -> INDEX kind preserved
    assert_equal [:index, 4, [0, 1, 3, 6]], desc[0]
  end

  def test_csa_single_true_promotes_to_degenerate_stride
    omit "requires CARRAY_DEV_BUILD" unless CAGrid.method_defined?(:_describe_axes)
    a = CArray.int(10, 4).seq
    m = CArray.boolean(10).tap { |__a| __a[] = [0, 0, 0, 1, 0, 0, 0, 0, 0, 0] }
    desc = a[m, nil]._describe_axes
    # Single TRUE at position 3 -> STRIDE(1, 3, 1)
    assert_equal [:stride, 1, 3, 1], desc[0]
  end

  def test_csa_empty_mask_keeps_index_kind
    omit "requires CARRAY_DEV_BUILD" unless CAGrid.method_defined?(:_describe_axes)
    a = CArray.int(10, 4).seq
    m = CArray.boolean(10).fill(0)
    desc = a[m, nil]._describe_axes
    assert_equal [:index, 0, []], desc[0]
  end

  # ---- CASelect (1-D filter) descriptor promotion (via xfer behavior) ----

  def test_caselect_all_true_byte_parity
    a = CArray.float64(20).seq
    m = CArray.boolean(20).fill(1)
    sel = a[m]
    addrs = (0...sel.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(sel, addrs, 1)
    assert_equal sel.to_ca.dump_binary, got
  end

  def test_caselect_block_true_byte_parity
    a = CArray.float64(20).seq
    m = CArray.boolean(20).tap { |__a| __a[] = [0]*5 + [1]*10 + [0]*5  }
    sel = a[m]
    addrs = (0...sel.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(sel, addrs, 1)
    assert_equal sel.to_ca.dump_binary, got
  end

  def test_caselect_random_mask_byte_parity_legacy
    a = CArray.float64(20).seq
    m = CArray.boolean(20).tap { |__a| __a[] = [1, 0, 0, 1, 1, 0, 1, 0, 0, 0, 1, 1, 1, 0, 0, 1, 0, 0, 1, 0] }
    sel = a[m]
    addrs = (0...sel.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(sel, addrs, 1)
    assert_equal sel.to_ca.dump_binary, got
  end

  # ---- Behavior preservation: all paths return same data ----

  def test_csa_all_true_xfer_all_matches_xfer_addrs
    a = CArray.float64(50, 8).seq
    m = CArray.boolean(50).fill(1)
    v = a[m, nil]
    bytes_all  = CArray.bench_xfer_all_get(v, 1)
    bytes_addr = CArray.bench_xfer_addrs_get(v, 1)
    assert_equal bytes_all, bytes_addr
    assert_equal v.to_ca.dump_binary, bytes_all
  end

  def test_csa_step3_mask_byte_parity
    a = CArray.float64(30, 8).seq
    m = CArray.boolean(30).tap { |i| i[] = i.is_a?(Integer) ? 0 : (i % 3 == 0 ? 1 : 0) }
    # use explicit list to be sure
    m = CArray.boolean(30)
    30.times { |i| m[i] = (i % 3 == 0 ? 1 : 0) }
    v = a[m, nil]
    bytes_all  = CArray.bench_xfer_all_get(v, 1)
    bytes_addr = CArray.bench_xfer_addrs_get(v, 1)
    assert_equal bytes_all, bytes_addr
    assert_equal v.to_ca.dump_binary, bytes_all
  end

  # ---- PUT round-trip preserved ----

  def test_csa_all_true_put_round_trip
    a = CArray.int64(8, 3)
    8.times { |i| 3.times { |j| a[i, j] = i * 10 + j } }
    m = CArray.boolean(8).fill(1)
    v = a[m, nil]
    payload = CArray.int64(8, 3)
    8.times { |i| 3.times { |j| payload[i, j] = -1 - i - j } }
    addrs = (0...v.elements).to_a
    CArray.bench_xfer_addrs_put_addrs(v, addrs, payload.dump_binary)
    assert_equal payload.to_a, v.to_a
  end
end

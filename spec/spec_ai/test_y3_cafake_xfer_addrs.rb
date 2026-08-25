# Y.3 (PROPOSAL_XFER_ADDRS_PER_REGION_GAPS.md §4): CAFake xfer_addrs
# sequential-run direct-cast fast path.  Skips intermediate scratch +
# scratch memcpy when addrs are sequential and parent is identity-
# resolvable to attached root.  Legacy 2-pass preserved for arbitrary
# addrs and non-identity parent.

require 'test/unit'
require 'carray'
require_relative "ext_xfer_smoke/load"
class TestY3CAFakeXferAddrs < Test::Unit::TestCase

  def setup
    @entity = CArray.int32(40, 25)
    40.times { |i| 25.times { |j| @entity[i, j] = i * 1000 + j } }
  end

  # ---- Whole-view sequential (= Y.3 fast path) ----

  def test_fake_whole_view_get
    fake = @entity.fake(:int64)
    addrs = (0...fake.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(fake, addrs, 1)
    assert_equal fake.to_ca.dump_binary, got
  end

  def test_fake_whole_view_put_round_trip
    target = @entity.dup
    fake = target.fake(:int64)
    payload = CArray.int64(fake.elements)
    fake.elements.times { |k| payload[k] = -1000 - k }
    addrs = (0...fake.elements).to_a
    CArray.bench_xfer_addrs_put_addrs(fake, addrs, payload.dump_binary)
    # int32 truncation: write -1000-k as int64 -> read back as int32
    fake.elements.times { |k| assert_equal((-1000 - k) & 0xFFFFFFFF, target.flatten[k] & 0xFFFFFFFF) }
  end

  # ---- Sub-region sequential ----

  def test_fake_subregion_sequential_get
    fake = @entity.fake(:int64)
    addrs = (100...500).to_a
    got = CArray.bench_xfer_addrs_get_addrs(fake, addrs, 1)
    expected = addrs.map { |a| fake[a / 25, a % 25] }.pack("q<*")
    assert_equal expected, got
  end

  # ---- Arbitrary addrs: legacy 2-pass path ----

  def test_fake_random_addrs_get
    fake = @entity.fake(:int64)
    addrs = [37, 5, 199, 2, 700, 11, 0, 999]
    got = CArray.bench_xfer_addrs_get_addrs(fake, addrs, 1)
    expected = addrs.map { |a| fake[a / 25, a % 25] }.pack("q<*")
    assert_equal expected, got
  end

  def test_fake_empty_addrs
    fake = @entity.fake(:int64)
    got = CArray.bench_xfer_addrs_get_addrs(fake, [], 1)
    assert_equal "", got
  end

  # ---- Virtual identity parent (= Y.1.e cascade through transform view) ----

  def test_fake_over_flatten_parent_whole_view
    flat = @entity.flatten   # virtual CARefer
    fake = flat.fake(:int64)
    addrs = (0...fake.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(fake, addrs, 1)
    assert_equal fake.to_ca.dump_binary, got
  end

  # ---- Non-identity parent: legacy path preserved ----

  def test_fake_over_transpose_uses_legacy
    # Transpose is CAStride but composed_strides not row-major -> resolver
    # returns original cand (= virtual transpose, no ptr) -> legacy 2-pass
    tp = @entity.transpose
    fake = tp.fake(:int64)
    addrs = (0...fake.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(fake, addrs, 1)
    assert_equal fake.to_ca.dump_binary, got
  end

  # ---- Different data_type casts ----

  def test_fake_int32_to_float64_whole_view
    fake = @entity.fake(:float64)
    addrs = (0...fake.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(fake, addrs, 1)
    assert_equal fake.to_ca.dump_binary, got
  end

  def test_fake_int32_to_uint8_whole_view
    fake = @entity.fake(:uint8)
    addrs = (0...fake.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(fake, addrs, 1)
    assert_equal fake.to_ca.dump_binary, got
  end

  def test_fake_float64_parent
    parent = CArray.float64(20, 10)
    20.times { |i| 10.times { |j| parent[i, j] = i * 0.5 + j * 0.0625 } }
    fake = parent.fake(:int32)
    addrs = (0...fake.elements).to_a
    got = CArray.bench_xfer_addrs_get_addrs(fake, addrs, 1)
    assert_equal fake.to_ca.dump_binary, got
  end
end

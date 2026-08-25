# Test for CArray#bincount_nd / CArray::BincountND (discrete N-D joint count).
# Exercises the autoload wiring too (plain `require "carray"`, no explicit
# require of carray/bincount_nd).

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../ext", __dir__)
require "test/unit"
require "carray"

class TestBincountND < Test::Unit::TestCase

  def test_autoload_via_plain_require
    # method + constant both resolve without explicit require
    d = CArray.int32(3, 1); d[nil, 0] = CA_INT32([0, 1, 1])
    h = d.bincount_nd(lengths: [3])
    assert_kind_of CArray::BincountND, h
  end

  def test_2d_joint_matches_ravel_bincount
    nx, ny, n = 4, 3, 50
    srand 1
    x = CArray.int32(n) { |i| rand(nx) }
    y = CArray.int32(n) { |i| rand(ny) }
    data = CArray.int32(n, 2); data[nil, 0] = x; data[nil, 1] = y
    h = data.bincount_nd(lengths: [nx, ny])
    ref = (x * ny + y).bincount(length: nx * ny).int64.reshape(nx, ny)
    assert_equal ref.to_a, h.counts.to_a
    assert_equal [nx + 1, ny + 1], h.full_counts.shape   # +1 per dim (upper overflow)
    assert_equal n, h.total
  end

  def test_upper_overflow
    # value >= length -> upper overflow cell, counted in total, not in counts
    d = CArray.int32(3, 2)
    d[0, nil] = CA_INT32([0, 0])    # in/in
    d[1, nil] = CA_INT32([4, 1])    # overflow on dim 0 (length 4 -> 0..3)
    d[2, nil] = CA_INT32([1, 9])    # overflow on dim 1
    h = d.bincount_nd(lengths: [4, 3])
    assert_equal 3, h.total
    assert_equal 1, h.counts.sum
    assert_equal 1, h.overflow(axis: 0)
    assert_equal 1, h.overflow(axis: 1)
    assert_equal 2, h.overflow_total
  end

  def test_negative_label_raises
    d = CArray.int32(3, 1); d[nil, 0] = CA_INT32([0, -1, 2])
    assert_raise(ArgumentError) { d.bincount_nd(lengths: [3]) }
  end

  def test_weighted
    d = CArray.int32(3, 1); d[nil, 0] = CA_INT32([0, 1, 1])
    h = d.bincount_nd(lengths: [3], weights: CA_FLOAT64([1.0, 2.0, 3.0]))
    assert_equal [1.0, 5.0, 0.0], h.counts.to_a
    assert_in_delta 6.0, h.total, 1e-9
  end

  def test_fiber
    # 2 fibers x 4 samples, M=2
    df = CArray.int32(2, 4, 2) { |f, a, c| (f + a + c) % 3 }
    h = df.bincount_nd(lengths: [3, 3], axis: [1, 2])
    assert_equal [2, 4, 4], h.full_counts.shape
    assert_equal [4, 4], h.total.to_a
  end

  def test_plus_composition
    a = CArray.int32(3, 1); a[nil, 0] = CA_INT32([0, 1, 1])
    b = CArray.int32(3, 1); b[nil, 0] = CA_INT32([1, 2, 2])
    hc = a.bincount_nd(lengths: [3]) + b.bincount_nd(lengths: [3])
    assert_equal [1, 3, 2], hc.counts.to_a
  end

  def test_plus_lengths_mismatch_raises
    a = CArray.int32(1, 1); a[nil, 0] = CA_INT32([0])
    h1 = a.bincount_nd(lengths: [3])
    h2 = a.bincount_nd(lengths: [4])
    assert_raise(ArgumentError) { h1 + h2 }
  end

  def test_streaming_via_add
    acc = CArray.int32(0, 1).bincount_nd(lengths: [3])
    acc.add(CA_INT32([0, 1]))
    acc.add(CA_INT32([1, 2, 2]))
    assert_equal [1, 2, 2], acc.counts.to_a
    assert_equal 5, acc.total
  end

  def test_new_is_private
    assert_raise(NoMethodError) { CArray::BincountND.new(lengths: [3]) }
  end

  def test_masked_label_skipped
    d = CArray.int32(4, 1).to_ca
    d[nil, 0] = CA_INT32([0, 1, 1, 2])
    d[2, 0] = UNDEF
    h = d.bincount_nd(lengths: [3])
    assert_equal [1, 1, 1], h.counts.to_a   # the masked label-1 sample dropped
    assert_equal 3, h.total
  end

end

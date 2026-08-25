# frozen_string_literal: true
#
# SO.3+ — partition family backed by quickselect kernel
# (PROPOSAL_SORT_AXIS rev8).
#
# Pins:
#   - partition(kth, axis: k) returns CARemap view via C-level
#     rb_ca_partitioned_view -> partition_addr_ki (= internal kernel,
#     bind_ruby: false) -> ca_remap_new
#   - partition_index(kth, axis: k) returns CA_SIZE fiber-local index
#     CArray via the public partition_index_ki(axis, kth) Ruby surface
#   - Quickselect contract: kth position is exact (= the kth-smallest
#     value / its index); positions < kth are <=; positions > kth are >=;
#     order WITHIN the < and > regions is unspecified (= NumPy contract).
#     Stability is NOT guaranteed inside those regions.
#   - Negative kth normalises (= -1 -> dim[axis] - 1, etc.)
#   - kth out-of-range raises ArgumentError
#   - Array kth rejected with ArgumentError
#   - CA_FIXLEN rejected with CADataTypeError (= partition kernel covers
#     ALL_NUMERIC only)
#   - Mask: any actually-masked raises; has-mask-field-only strips

require "test/unit"
require "carray"

class TestPartitionSO3Plus < Test::Unit::TestCase

  # ---- partition view contract -----------------------------------------

  def test_partition_returns_caremap
    a = CArray.int32(7)
    [5, 3, 1, 4, 2, 7, 6].each_with_index { |v, i| a[i] = v }
    p = a.partition(3, axis: 0)
    assert_equal(CARemap, p.class)
    assert_equal([7], p.dim.to_a)
  end

  def test_partition_kth_position_is_exact
    a = CArray.int32(7)
    [5, 3, 1, 4, 2, 7, 6].each_with_index { |v, i| a[i] = v }
    sorted = a.to_a.sort
    (0..6).each do |k|
      p = a.partition(k, axis: 0)
      assert_equal(sorted[k], p[k],
                   "kth=#{k}: partition[k] should be the kth-smallest")
    end
  end

  def test_partition_contract_2d
    b = CArray.int32(3, 5)
    [[5, 1, 4, 2, 3], [10, 6, 9, 7, 8], [15, 11, 14, 12, 13]]
      .each_with_index do |row, i|
      row.each_with_index { |v, j| b[i, j] = v }
    end
    kth = 2
    p = b.partition(kth, axis: 1)
    b.dim[0].times do |i|
      row = (0...b.dim[1]).map { |j| p[i, j] }
      sorted_row = (0...b.dim[1]).map { |j| b[i, j] }.sort
      # Position kth holds the kth-smallest exactly
      assert_equal(sorted_row[kth], row[kth],
                   "row #{i}: kth=#{kth} position should be sorted_row[#{kth}]")
      # Positions < kth all <= sorted_row[kth]
      assert(row[0...kth].all? { |v| v <= sorted_row[kth] },
             "row #{i}: positions < kth should all be <= kth value")
      # Positions > kth all >= sorted_row[kth]
      assert(row[(kth+1)..].all? { |v| v >= sorted_row[kth] },
             "row #{i}: positions > kth should all be >= kth value")
    end
  end

  def test_partition_negative_kth
    a = CArray.int32(5)
    [3, 1, 4, 1, 5].each_with_index { |v, i| a[i] = v }
    # kth = -1 normalises to 4 (= last position)
    p = a.partition(-1, axis: 0)
    assert_equal(5, p[4])  # last position holds the max
    # kth = -5 normalises to 0 (= first position)
    p2 = a.partition(-5, axis: 0)
    assert_equal(1, p2[0])  # first position holds the min
  end

  # ---- partition_index contract ----------------------------------------

  def test_partition_index_returns_fiber_local_indices
    a = CArray.int32(7)
    [5, 3, 1, 4, 2, 7, 6].each_with_index { |v, i| a[i] = v }
    pi = a.partition_index(3, axis: 0)
    assert_kind_of(CArray, pi)
    assert_equal([7], pi.dim.to_a)
    assert_equal(CA_INT64, pi.data_type)  # CA_SIZE on 64-bit
    # Position kth holds the index of the kth-smallest value
    assert_equal(4, a[pi[3]])  # sorted[3] = 4 in original
  end

  def test_partition_index_2d
    b = CArray.int32(2, 5)
    [[5, 1, 4, 2, 3], [10, 6, 9, 7, 8]].each_with_index do |row, i|
      row.each_with_index { |v, j| b[i, j] = v }
    end
    pi = b.partition_index(2, axis: 1)
    assert_equal([2, 5], pi.dim.to_a)
    # row 0 sorted = [1,2,3,4,5]; kth=2 -> value 3 -> original idx 4
    # row 1 sorted = [6,7,8,9,10]; kth=2 -> value 8 -> original idx 4
    assert_equal(4, pi[0, 2])
    assert_equal(4, pi[1, 2])
  end

  # ---- validation errors ----------------------------------------------

  def test_partition_kth_out_of_range
    a = CArray.int32(4).seq
    assert_raise(ArgumentError) { a.partition(4) }
    assert_raise(ArgumentError) { a.partition(-5) }
  end

  def test_partition_index_kth_out_of_range
    a = CArray.int32(4).seq
    assert_raise(ArgumentError) { a.partition_index(4) }
    assert_raise(ArgumentError) { a.partition_index(-5) }
  end

  def test_partition_array_kth_rejected
    a = CArray.int32(5).seq
    # C dispatcher routes kth through NUM2SIZE; Array -> TypeError.
    assert_raise(TypeError) { a.partition_index([1, 2]) }
  end

  # CA_FIXLEN per-axis partition is supported as of the fixlen sort-family
  # dialect (3.0): memcmp lexicographic order, same as fixlen `<` / `>`.
  def test_partition_fixlen_supported
    f = CArray.fixlen(3, bytes: 2)
    %w[bb aa cc].each_with_index { |v, i| f[i] = v }
    part = f.partition(1, axis: 0)
    # kth=1 holds the 1st-smallest of sorted [aa, bb, cc] = "bb".
    assert_equal("bb", part[1])
    assert_equal(f.sort_copy[1], part[1])
  end

  def test_partition_masked_input_clusters_to_masked_position
    a = CArray.float64(5).seq
    a[2] = UNDEF                                # [0, 1, UNDEF, 3, 4]
    p_last = a.partition(2, axis: 0)            # valid slice [0,1,3,4] kth=2 -> 3
    assert_equal([0.0, 1.0, 3.0, 4.0, UNDEF], p_last.to_a)
    assert_equal([false, false, false, false, true], p_last.mask.to_a)

    p_first = a.partition(2, axis: 0, masked_position: :first)
    assert_equal([UNDEF, 0.0, 1.0, 3.0, 4.0], p_first.to_a)
    assert_equal([true, false, false, false, false], p_first.mask.to_a)
  end

  def test_partition_index_masked_input_clusters_to_masked_position
    a = CArray.float64(5).seq
    a[2] = UNDEF
    assert_equal([0, 1, 3, 4, 2], a.partition_index(2, axis: 0).to_a)
    assert_equal([2, 0, 1, 3, 4], a.partition_index(2, axis: 0, masked_position: :first).to_a)
  end

  # ---- view chain transparency -----------------------------------------

  def test_partition_on_transpose_view
    a = CArray.int32(3, 4).seq
    tv = a.transpose                  # shape (4, 3)
    p = tv.partition(1, axis: 1)
    assert_equal(CARemap, p.class)
    assert_equal([4, 3], p.dim.to_a)
    # Each tv row has 3 elements; sorted by column index in a
    tv.dim[0].times do |i|
      row_orig = (0...tv.dim[1]).map { |j| tv[i, j] }
      row_part = (0...tv.dim[1]).map { |j| p[i, j] }
      sorted_row = row_orig.sort
      assert_equal(sorted_row[1], row_part[1],
                   "row #{i}: kth=1 position should be sorted_row[1]")
    end
  end

  # ---- kernel surface direct (= partition_index_ki) --------------------

  def test_partition_index_ki_arity
    # partition_index_ki(axis, kth) -- 2 positional args
    a = CArray.int32(5).seq
    assert_equal(2, CArray.instance_method(:partition_index_ki).arity)
    pi = a.partition_index_ki(0, 2)
    assert_kind_of(CArray, pi)
    assert_equal(2, a[pi[2]])  # kth=2 -> value 2
  end

  # ---- large fiber quickselect correctness -----------------------------

  def test_quickselect_large_fiber
    # 1000-element fiber; verify each kth in a sample
    srand(42)
    a = CArray.float64(1000)
    1000.times { |i| a[i] = rand }
    sorted = a.to_a.sort
    [0, 1, 100, 499, 500, 999].each do |kth|
      p = a.partition(kth, axis: 0)
      assert_in_delta(sorted[kth], p[kth], 1e-12,
                      "kth=#{kth}: quickselect should match sorted[kth]")
    end
  end

  # ---- regression: SO.3 surface still works  ---------------------------

  def test_partition_back_compat_kth_irrelevant_to_kth_position
    # SO.3 minimum guaranteed sorted output (= stronger than partition).
    # SO.3+ no longer guarantees full sort but still guarantees kth.
    # Verify each kth's value matches sorted regardless of where other
    # cells land.
    a = CArray.int32(10)
    [3, 7, 1, 9, 4, 6, 2, 8, 5, 0].each_with_index { |v, i| a[i] = v }
    sorted = a.to_a.sort
    [0, 3, 5, 7, 9].each do |kth|
      p = a.partition(kth, axis: 0)
      assert_equal(sorted[kth], p[kth], "kth=#{kth}")
    end
  end

end

# PROPOSAL_SLAB_FAMILY β.2 — map_slab live tests
#
# Scope (= β.2 first cut, proposal §5.3 acceptance):
#   - single-axis slab (axis: Integer / negative / -1 / 0 / inner / outer)
#   - data_type default = self.data_type; data_type: kwarg override (Symbol)
#   - block returns CArray (same shape) → scatter, with cast on mismatch
#   - block returns Numeric scalar → broadcast fill
#   - CA_OBJECT output → any VALUE broadcast (proposal §1.2 待ち customer)
#   - error: shape mismatch / wrong type / missing block / bad axis
#   - 2-D / 3-D source
#   - axis-0 (= non-contig slab, F.6 PER_FIBER_FUSED path) parity
#
# Multi-axis slab (axis: [k1, k2]) + mask transparent carry = β.2b sub-step,
# omit-marked here.

require 'test/unit'
require 'carray'

class TestMapSlabBeta2 < Test::Unit::TestCase

  # ---- identity + basic shape preservation

  def test_identity_axis_inner
    a = CArray.float64(3, 4).seq!
    b = a.map_slab(axis: 1) { |row| row }
    assert_equal a.to_a, b.to_a
    assert_equal [3, 4], b.dim.to_a
  end

  def test_identity_axis_outer
    a = CArray.float64(3, 4).seq!
    b = a.map_slab(axis: 0) { |col| col }
    assert_equal a.to_a, b.to_a
  end

  def test_identity_via_dup
    a = CArray.float64(3, 4).seq!
    b = a.map_slab(axis: 1) { |row| row.dup }
    assert_equal a.to_a, b.to_a
  end

  # ---- per-slab transform

  def test_center_per_row
    a = CArray.float64(3, 4).seq!
    b = a.map_slab(axis: 1) { |row| row - row.mean }
    expected = [
      [-1.5, -0.5, 0.5, 1.5],
      [-1.5, -0.5, 0.5, 1.5],
      [-1.5, -0.5, 0.5, 1.5]
    ]
    assert_equal expected, b.to_a
  end

  def test_double_per_column
    a = CArray.float64(3, 4).seq!
    b = a.map_slab(axis: 0) { |col| col * 2 }
    expected = a.to_a.map { |row| row.map { |v| v * 2 } }
    assert_equal expected, b.to_a
  end

  def test_axis_negative
    a = CArray.float64(3, 4).seq!
    b = a.map_slab(axis: -1) { |row| row + 1 }
    expected = a.to_a.map { |row| row.map { |v| v + 1 } }
    assert_equal expected, b.to_a
  end

  # ---- sort per axis (= 待ち customer)

  def test_sort_per_row
    a = CArray.int32(3, 4) { |i, j| (3 - i) * 4 - j }
    b = a.map_slab(axis: 1) { |row| row.sort }
    assert_equal [[9, 10, 11, 12], [5, 6, 7, 8], [1, 2, 3, 4]], b.to_a
  end

  def test_sort_per_column
    a = CArray.int32(3, 4) { |i, j| (i + 1) * 10 - (i + j) * 5 }
    b = a.map_slab(axis: 0) { |col| col.sort }
    cols_expected = (0...4).map { |j| (0...3).map { |i| a[i, j] }.sort }
    expected = (0...3).map { |i| (0...4).map { |j| cols_expected[j][i] } }
    assert_equal expected, b.to_a
  end

  # ---- scalar return → broadcast

  def test_scalar_sum_broadcast
    a = CArray.float64(3, 4).seq!
    b = a.map_slab(axis: 1) { |row| row.sum }
    assert_equal [[6, 6, 6, 6], [22, 22, 22, 22], [38, 38, 38, 38]],
                 b.to_a.map { |row| row.map(&:to_i) }
  end

  def test_scalar_integer_on_float_output
    a = CArray.float64(2, 3).seq!
    b = a.map_slab(axis: 1) { |_| 42 }
    assert_equal [[42.0, 42.0, 42.0], [42.0, 42.0, 42.0]], b.to_a
  end

  # ---- data_type override

  def test_data_type_kwarg_int32
    a = CArray.float64(3, 4).seq!
    b = a.map_slab(axis: 1, data_type: :int32) { |row| row * 10 }
    assert_equal :int32, b.data_type_name.to_sym
    assert_equal [[0, 10, 20, 30], [40, 50, 60, 70], [80, 90, 100, 110]],
                 b.to_a
  end

  def test_data_type_default_matches_source
    a = CArray.int32(2, 3).seq!
    b = a.map_slab(axis: 1) { |row| row }
    assert_equal :int32, b.data_type_name.to_sym
  end

  # ---- 3-D source

  def test_3d_row_sum_along_last_axis
    a = CArray.int32(2, 3, 4).seq!
    b = a.map_slab(axis: -1) { |row| row.sum }
    # each fiber along axis=-1 has 4 elements; sum is broadcast over those 4.
    expected = (0...2).flat_map do |i|
      (0...3).map { |j| s = (0...4).sum { |k| i * 12 + j * 4 + k }; [s] * 4 }
    end.each_slice(3).to_a
    assert_equal expected, b.to_a
  end

  def test_3d_axis_middle
    a = CArray.int32(2, 3, 4).seq!
    b = a.map_slab(axis: 1) { |fiber| fiber + 100 }
    expected = a.to_a.map { |sl| sl.map { |row| row.map { |v| v + 100 } } }
    assert_equal expected, b.to_a
  end

  # ---- CA_OBJECT per-axis (= 待ち customer)

  def test_object_data_type_scalar_broadcast
    a = CArray.object(2, 3) { |i, j| "r#{i}c#{j}" }
    b = a.map_slab(axis: 1) { |row| row.to_a.join(",") }
    assert_equal "r0c0,r0c1,r0c2", b[0, 0]
    assert_equal "r1c0,r1c1,r1c2", b[1, 0]
    # broadcast: every cell in row 0 holds the same joined string
    assert_equal b[0, 0], b[0, 1]
    assert_equal b[0, 0], b[0, 2]
  end

  def test_object_data_type_sort_per_row_via_to_ca
    # CArray#sort does not support CA_OBJECT directly (sort_addr_ki
    # numeric data_types only), so the user converts to Ruby Array, sorts,
    # and wraps back in a fresh object CArray.  This is the natural
    # pattern β.2 enables for CA_OBJECT/CA_FIXLEN per-axis sort.
    a = CArray.object(2, 3) { |i, j| ["zebra", "apple", "mango"][j] + "-#{i}" }
    b = a.map_slab(axis: 1) do |row|
      sorted = row.to_a.sort
      CArray.object(sorted.size) { |i| sorted[i] }
    end
    assert_equal ["apple-0", "mango-0", "zebra-0"], b[0, nil].to_a
    assert_equal ["apple-1", "mango-1", "zebra-1"], b[1, nil].to_a
  end

  # ---- error cases (= proposal §3.1 strict contract)

  def test_raises_without_block
    a = CArray.float64(3, 4).seq!
    assert_raise(LocalJumpError) { a.map_slab(axis: 1) }
  end

  def test_raises_on_shape_mismatch
    a = CArray.float64(3, 4).seq!
    assert_raise(ArgumentError) do
      a.map_slab(axis: 1) { |_| CArray.float64(99).seq! }
    end
  end

  def test_raises_on_bad_return_type_numeric_output
    a = CArray.float64(3, 4).seq!
    assert_raise(ArgumentError) { a.map_slab(axis: 1) { :bogus } }
  end

  def test_raises_on_array_return_numeric_output
    a = CArray.float64(3, 4).seq!
    assert_raise(ArgumentError) { a.map_slab(axis: 1) { [1, 2, 3, 4] } }
  end

  def test_raises_on_axis_out_of_range
    a = CArray.float64(3, 4).seq!
    assert_raise(ArgumentError) { a.map_slab(axis: 99) { |_| 0 } }
  end

  # β.xc' Piece A/B: multi-axis map_slab works for both contig innermost-K
  # AND non-contig cases (= own-scratch K-D gather + scatter).
  def test_multi_axis_map_slab_works
    a = CArray.float64(2, 3, 4).seq!
    out = a.map_slab(axis: [1, 2]) { |slab| slab + 100 }
    assert_equal a.dim.to_a, out.dim.to_a
    assert_equal [100.0, 101.0, 102.0, 103.0], out[0, 0, nil].to_a
  end

  # β.xb mask carry: input mask is visible to the block; output mask is
  # currently dropped (= simplest contract for first cut).
  def test_masked_source_carries_input_mask
    a = CArray.float64(3, 4).seq!
    a[0, 0] = UNDEF
    a[1, 2] = UNDEF
    seen_masks = []
    a.map_slab(axis: 1) { |row| seen_masks << row.mask.to_a; row.sum }
    assert_equal [[true, false, false, false], [false, false, true, false], [false, false, false, false]], seen_masks
  end

  # ---- block-side reflection: source semantics preserved

  def test_block_receives_correct_length
    a = CArray.float64(3, 4).seq!
    seen_lengths = []
    a.map_slab(axis: 1) { |row| seen_lengths << row.dim[0]; row }
    assert_equal [4, 4, 4], seen_lengths
  end

  def test_block_receives_distinct_content_per_iter
    a = CArray.int32(3, 4).seq!
    seen = []
    a.map_slab(axis: 1) { |row| seen << row.to_a; row }
    assert_equal [[0, 1, 2, 3], [4, 5, 6, 7], [8, 9, 10, 11]], seen
  end

  # ---- in-block derived view path (= clone / compose-fold)
  #
  # PIN purpose (= 2026-06-09 設計担当 directive #4):
  #   memo §5.2 audit blind spot — when slab_view is mutated only via
  #   `ptr` and the user creates a derived view inside the block
  #   (`row.dup`, `row[1..2]`, `row > 0`, `row + 1`, `row.copy`), the
  #   derived view must reflect the **current** iter's slab data, not
  #   iter 0's. The original CAStride-with-ptr-only-mutation design
  #   missed this because ca_stride_func_clone (ext/ca_obj_stride.c:380)
  #   ignores ptr and re-composes from (parent, base_offset, strides).
  #
  #   These tests must PASS on any correct implementation (CAWrap, or
  #   CAStride with base_offset per-iter slide). They are the contract
  #   pin for "in-block derived view = current iter".

  def test_row_dup_returns_current_iter_data_per_iter
    a = CArray.float64(3, 4).seq!   # [[0,1,2,3],[4,5,6,7],[8,9,10,11]]
    seen = []
    a.map_slab(axis: 1) { |row| seen << row.dup.to_a; row }
    assert_equal [[0.0, 1.0, 2.0, 3.0],
                  [4.0, 5.0, 6.0, 7.0],
                  [8.0, 9.0, 10.0, 11.0]], seen
  end

  def test_row_dup_outputs_correctly_when_returned
    a = CArray.float64(3, 4).seq!
    b = a.map_slab(axis: 1) { |row| row.dup }
    assert_equal a.to_a, b.to_a
  end

  def test_row_dup_axis_0_per_iter
    # axis 0 = non-contig fiber in source memory; T1 may scratch-gather.
    # `row.dup` via compose-fold must still read CURRENT iter's column.
    a = CArray.int32(3, 4) { |i, j| i * 10 + j }
    seen = []
    a.map_slab(axis: 0) { |col| seen << col.dup.to_a; col }
    # 4 iters (one per axis-1 position); each col is [src[0,j], src[1,j], src[2,j]]
    expected = (0...4).map { |j| (0...3).map { |i| i * 10 + j } }
    assert_equal expected, seen
  end

  def test_row_bracket_slice_full_returns_current_iter
    # Use a same-length slice (= identity slice) so shape matches.
    a = CArray.float64(3, 4).seq!
    seen = []
    a.map_slab(axis: 1) do |row|
      seen << row[0..-1].to_a
      row
    end
    assert_equal [[0.0, 1.0, 2.0, 3.0],
                  [4.0, 5.0, 6.0, 7.0],
                  [8.0, 9.0, 10.0, 11.0]], seen
  end

  def test_row_arithmetic_returns_current_iter
    a = CArray.float64(3, 4).seq!
    b = a.map_slab(axis: 1) { |row| row + 1 }
    expected = a.to_a.map { |r| r.map { |v| v + 1 } }
    assert_equal expected, b.to_a
  end

  def test_row_comparison_returns_current_iter
    a = CArray.int32(3, 4) { |i, j| (i - 1) * 4 + j }   # mixed signs
    # `row > 0` returns bool CArray same shape as row.  Scatter is via
    # cast-on-scatter into int32 output (true→1, false→0).
    b = a.map_slab(axis: 1) { |row| (row > 0).as_int32 }
    expected = a.to_a.map { |r| r.map { |v| v > 0 ? 1 : 0 } }
    assert_equal expected, b.to_a
  end

  def test_row_copy_returns_current_iter_snapshot
    a = CArray.float64(3, 4).seq!
    snapshots = []
    a.map_slab(axis: 1) { |row| snapshots << row.copy; row }
    # Each snapshot must hold its iter's data, NOT iter 0's data.
    assert_equal [0.0, 1.0, 2.0, 3.0],   snapshots[0].to_a
    assert_equal [4.0, 5.0, 6.0, 7.0],   snapshots[1].to_a
    assert_equal [8.0, 9.0, 10.0, 11.0], snapshots[2].to_a
  end

  def test_row_compound_derived_view_reads_current_iter
    # Deep derived view: (row + 1) * 2 - 0.5
    a = CArray.float64(3, 4).seq!
    b = a.map_slab(axis: 1) { |row| (row + 1) * 2 - 0.5 }
    expected = a.to_a.map { |r| r.map { |v| (v + 1) * 2 - 0.5 } }
    assert_equal expected, b.to_a
  end

  # ---- rb_ensure cleanup: exception in block does not leak

  def test_exception_in_block_propagates_and_cleans_up
    a = CArray.float64(3, 4).seq!
    raised = false
    begin
      a.map_slab(axis: 1) { |_| raise "boom" }
    rescue => e
      raised = (e.message == "boom")
    end
    assert raised, "user exception must propagate"
    # If T1 finish did not run, GC alone would not crash but a subsequent
    # call should still succeed — exercising the lifecycle once more pins
    # the state machine's idempotence.
    b = a.map_slab(axis: 1) { |row| row }
    assert_equal a.to_a, b.to_a
  end
end

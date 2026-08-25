# PROPOSAL_SLAB_FAMILY β.4 — each_slab live tests
#
# Scope (= β.4 first cut, proposal §5.5 acceptance):
#   - single-axis side-effect iteration; block return discarded
#   - returns self after natural completion
#   - axis negative / 0 (= SCRATCH carrier path) / inner / outer
#   - to_enum support (= no-block call returns Enumerator)
#   - Ruby flow control: break / next / return propagate correctly via rb_ensure
#   - slab persistence trap (= memo §5.2.3): persistence is undefined; .copy
#     / .dup / .to_a snapshot the current iter
#   - mask transparent carry = β.4b (currently raises NotImpError)
#   - multi-axis = NotImpError

require 'test/unit'
require 'carray'

class TestEachSlabBeta4 < Test::Unit::TestCase

  # ---- basic iteration

  def test_yields_each_fiber_axis_inner
    a = CArray.float64(3, 4).seq!
    seen = []
    a.each_slab(axis: 1) { |row| seen << row.to_a }
    assert_equal [[0.0, 1.0, 2.0, 3.0],
                  [4.0, 5.0, 6.0, 7.0],
                  [8.0, 9.0, 10.0, 11.0]], seen
  end

  def test_yields_each_fiber_axis_outer_SCRATCH
    a = CArray.float64(3, 4).seq!
    seen = []
    a.each_slab(axis: 0) { |col| seen << col.to_a }
    assert_equal [[0.0, 4.0, 8.0],
                  [1.0, 5.0, 9.0],
                  [2.0, 6.0, 10.0],
                  [3.0, 7.0, 11.0]], seen
  end

  def test_yields_each_fiber_axis_negative
    a = CArray.float64(3, 4).seq!
    seen = []
    a.each_slab(axis: -1) { |row| seen << row.to_a }
    assert_equal 3, seen.size
    assert_equal [0.0, 1.0, 2.0, 3.0], seen.first
  end

  def test_yields_each_fiber_3d
    a = CArray.int32(2, 3, 4).seq!
    seen_lens = []
    a.each_slab(axis: -1) { |fiber| seen_lens << fiber.dim[0] }
    assert_equal [4] * 6, seen_lens   # 2 * 3 outer iters, each fiber length 4
  end

  # ---- return value

  def test_returns_self_after_natural_completion
    a = CArray.float64(3, 4).seq!
    r = a.each_slab(axis: 1) { |row| row.sum }
    assert_same a, r
  end

  # ---- block return discarded

  def test_block_return_is_discarded
    a = CArray.float64(3, 4).seq!
    # Block returns various objects per iter; map_slab would scatter
    # them, reduce_slab would scalar-collect, but each_slab discards.
    a.each_slab(axis: 1) { |row| row.sum }
    # No assertion on output — just confirm no raise.
    a.each_slab(axis: 1) { |row| "string" }
    a.each_slab(axis: 1) { |row| nil }
    a.each_slab(axis: 1) { |row| [1, 2, 3] }
  end

  # ---- Enumerator support (= proposal §3.3)

  def test_returns_enumerator_when_no_block_given
    a = CArray.float64(3, 4).seq!
    e = a.each_slab(axis: 1)
    assert_kind_of Enumerator, e
  end

  def test_enumerator_yields_per_iter
    a = CArray.float64(3, 4).seq!
    # .map { |s| s.sum } extracts scalar per iter — safe pattern.
    # (.to_a would capture references to the same persistence-trapped slab.)
    sums = a.each_slab(axis: 1).map { |row| row.sum }
    assert_equal [6.0, 22.0, 38.0], sums
  end

  def test_enumerator_with_index
    a = CArray.float64(3, 4).seq!
    pairs = a.each_slab(axis: 1).each_with_index.map { |row, i| [i, row.sum] }
    assert_equal [[0, 6.0], [1, 22.0], [2, 38.0]], pairs
  end

  # ---- Ruby flow control

  def test_break_propagates_via_rb_ensure
    a = CArray.float64(3, 4).seq!
    seen = []
    a.each_slab(axis: 1) do |row|
      seen << row.to_a
      break if seen.size == 2
    end
    assert_equal 2, seen.size
  end

  def test_break_with_value
    a = CArray.float64(3, 4).seq!
    r = a.each_slab(axis: 1) { |row| break :stopped if row.sum > 5 }
    assert_equal :stopped, r
  end

  def test_next_skips_iter
    a = CArray.float64(3, 4).seq!
    kept = []
    a.each_slab(axis: 1) do |row|
      next if row.sum > 10
      kept << row.to_a
    end
    assert_equal [[0.0, 1.0, 2.0, 3.0]], kept
  end

  # ---- snapshot patterns (= persistence trap awareness)

  def test_to_a_snapshot_in_block_works
    # The safe pattern: convert to plain Ruby data inside the block.
    a = CArray.int32(3, 4).seq!
    rows_as_arrays = []
    a.each_slab(axis: 1) { |row| rows_as_arrays << row.to_a }
    assert_equal [[0, 1, 2, 3], [4, 5, 6, 7], [8, 9, 10, 11]],
                 rows_as_arrays
  end

  def test_dup_snapshot_in_block_works
    a = CArray.int32(3, 4).seq!
    rows_dup = []
    a.each_slab(axis: 1) { |row| rows_dup << row.dup }
    assert_equal [[0, 1, 2, 3], [4, 5, 6, 7], [8, 9, 10, 11]],
                 rows_dup.map(&:to_a)
  end

  def test_capturing_slab_reference_is_persistence_trapped
    # PIN memo §5.2.3 semantic: capturing the slab object reference (not
    # a snapshot) ends up with every entry referring to the SAME slab
    # object, which shows only the last iter's data.  We document this
    # here as a known no-op contract, not a bug to fix.
    a = CArray.int32(3, 4).seq!
    refs = []
    a.each_slab(axis: 1) { |row| refs << row }
    # All entries are the same slab object (= per-iter reuse).
    assert_equal 1, refs.uniq.size
    # That object now shows the last iter's data.
    assert_equal [8, 9, 10, 11], refs.first.to_a
  end

  # ---- in-block derived view safety (= memo §5.2 audit blind spot)

  def test_in_block_row_dup_reads_current_iter
    a = CArray.float64(3, 4).seq!
    duped = []
    a.each_slab(axis: 1) { |row| duped << row.dup.to_a }
    assert_equal [[0.0, 1.0, 2.0, 3.0],
                  [4.0, 5.0, 6.0, 7.0],
                  [8.0, 9.0, 10.0, 11.0]], duped
  end

  def test_in_block_arithmetic_reads_current_iter
    a = CArray.float64(3, 4).seq!
    sums_plus_one = []
    a.each_slab(axis: 1) { |row| sums_plus_one << (row + 1).sum }
    # row i sum = sum(0..3) + 4*i = 6 + 16i, plus 4 from +1 per element
    expected = [6.0 + 4.0, 22.0 + 4.0, 38.0 + 4.0]
    assert_equal expected, sums_plus_one
  end

  # ---- errors

  def test_raises_on_axis_out_of_range
    a = CArray.float64(3, 4).seq!
    assert_raise(ArgumentError) { a.each_slab(axis: 99) { |row| } }
  end

  # Ported from test_slab_iterator_basic.rb during the slab API refactor
  # (PROPOSAL_SLAB_API_REFACTOR §3.5): negative axis below -ndim must
  # raise just like positive axis past ndim-1.
  def test_raises_on_axis_negative_out_of_range
    a = CArray.float64(3, 4).seq!
    assert_raise(ArgumentError) { a.each_slab(axis: -99) { |row| } }
  end

  # Ported from test_slab_iterator_basic.rb during the slab API refactor:
  # duplicate axes in the K-D form must raise (e.g. axis: [1, 1]).
  def test_raises_on_duplicate_axis
    a = CArray.float64(3, 4, 5).seq!
    assert_raise(ArgumentError) { a.each_slab(axis: [1, 1]) { |slab| } }
  end

  # β.xc' Piece B: non-contig multi-axis works via own-scratch K-D gather.
  # Comprehensive multi-axis tests live in test_slab_multi_axis.rb.
  def test_non_contig_multi_axis_works_via_own_scratch
    a = CArray.float64(2, 3, 4).seq!
    seen = []
    a.each_slab(axis: [0, 1]) { |slab| seen << slab.sum }
    assert_equal 4, seen.size   # outer = axis 2 with dim=4
  end

  # β.xb mask carry: slab.mask / slab.has_mask? / slab.to_a expose the
  # masked elements directly.
  def test_masked_source_carries_input_mask_axis_inner
    a = CArray.float64(3, 4).seq!
    a[0, 0] = UNDEF
    seen = []
    a.each_slab(axis: 1) { |row| seen << row.mask.to_a }
    assert_equal [[true, false, false, false], [false, false, false, false], [false, false, false, false]], seen
  end

  def test_masked_source_carries_input_mask_axis_outer_SCRATCH
    a = CArray.float64(3, 4).seq!
    a[1, 2] = UNDEF
    seen = []
    a.each_slab(axis: 0) { |col| seen << col.mask.to_a }
    # Column j=2 has mask [0, 1, 0] at i=1
    assert_equal [[false, false, false], [false, false, false], [false, true, false], [false, false, false]], seen
  end

  # ---- rb_ensure cleanup

  def test_exception_in_block_propagates_and_cleans_up
    a = CArray.float64(3, 4).seq!
    raised = false
    begin
      a.each_slab(axis: 1) { |_| raise "boom" }
    rescue => e
      raised = (e.message == "boom")
    end
    assert raised
    # Subsequent each_slab call still works (= state machine clean).
    seen = []
    a.each_slab(axis: 1) { |row| seen << row.sum }
    assert_equal [6.0, 22.0, 38.0], seen
  end
end

require "test/unit"
require "carray"

# CAFrame#[]= — row-level assignment (docs/topics/Indexer_decision_tree.md).
#
# The RHS value decides the operation, the key selects the rows:
#   df[sel] = UNDEF -> mask the selected rows (shape unchanged, write-through)
#   df[sel] = nil   -> delete the selected rows (frame shrinks)
#   df[sel] = other -> splice the contiguous span with other's rows (Array#[]=)
#
# sel is a row-axis indexer key, classified as a 1-D column key: a slice
# (BLOCK — Range / ArithmeticSequence / [start, count, step]), a boolean CArray
# (SELECT), an integer CArray (GRID), or an Integer.

class TestCAFrameRowMask < Test::Unit::TestCase
  def mk
    CAFrame.new("a" => CArray.int32(6).seq(0), "b" => CArray.float64(6) { |i| i * 10.0 })
  end

  def test_mask_range_masks_every_column_keeps_shape
    df = mk
    df[2..3] = UNDEF
    assert_equal 6, df.nrow
    assert_equal [false, false, true, true, false, false], df["a"].is_masked.to_a
    assert_equal [false, false, true, true, false, false], df["b"].is_masked.to_a
  end

  def test_mask_boolean_selector
    df = mk
    df[df["a"].gt(3)] = UNDEF
    assert_equal [false, false, false, false, true, true], df["a"].is_masked.to_a
  end

  def test_mask_integer_selector
    df = mk
    df[3] = UNDEF
    assert_equal [false, false, false, true, false, false], df["a"].is_masked.to_a
  end

  def test_mask_arithmetic_sequence_slice
    df = mk
    df[(0..4).step(2)] = UNDEF
    assert_equal [true, false, true, false, true, false], df["a"].is_masked.to_a
  end

  def test_mask_block_array_slice
    df = mk
    df[[1, 3, 1]] = UNDEF   # start 1, count 3, step 1
    assert_equal [false, true, true, true, false, false], df["a"].is_masked.to_a
  end

  def test_mask_keeps_index
    df = CAFrame.new("a" => CA_INT32([1, 2, 3, 4]), index: CA_OBJECT(["w", "x", "y", "z"]))
    df[1..2] = UNDEF
    assert_equal [false, true, true, false], df["a"].is_masked.to_a
    assert_equal ["w", "x", "y", "z"], df.index.to_a   # index untouched
  end

  def test_mask_returns_the_rhs
    df = mk
    assert_same UNDEF, (df[0] = UNDEF)
  end
end

class TestCAFrameRowDelete < Test::Unit::TestCase
  def mk
    CAFrame.new("a" => CArray.int32(6).seq(0), "b" => CArray.float64(6) { |i| i * 10.0 })
  end

  def test_delete_range_shrinks_and_preserves_order
    df = mk
    df[2..3] = nil
    assert_equal 4, df.nrow
    assert_equal [0, 1, 4, 5], df["a"].to_a
    assert_equal [0.0, 10.0, 40.0, 50.0], df["b"].to_a
  end

  def test_delete_single_row
    df = mk
    df[3] = nil
    assert_equal [0, 1, 2, 4, 5], df["a"].to_a
  end

  def test_delete_boolean_selector
    df = mk
    df[df["a"].lt(2)] = nil
    assert_equal [2, 3, 4, 5], df["a"].to_a
  end

  def test_delete_integer_array_selector
    df = mk
    df[CA_INT32([0, 5])] = nil
    assert_equal [1, 2, 3, 4], df["a"].to_a
  end

  def test_delete_strided_slice
    df = mk
    df[(0..5).step(2)] = nil   # remove rows 0, 2, 4
    assert_equal [1, 3, 5], df["a"].to_a
  end

  def test_delete_carries_the_index
    df = CAFrame.new("a" => CA_INT32([1, 2, 3, 4]), index: CA_OBJECT(["w", "x", "y", "z"]))
    df[1] = nil
    assert_equal [1, 3, 4], df["a"].to_a
    assert_equal ["w", "y", "z"], df.index.to_a
  end

  def test_delete_all_rows_empties_frame
    df = mk
    df[0..5] = nil
    assert_equal 0, df.nrow
    assert_equal [], df["a"].to_a
  end
end

class TestCAFrameRowSplice < Test::Unit::TestCase
  def mk
    CAFrame.new("a" => CArray.int32(6).seq(0), "b" => CArray.float64(6) { |i| i * 10.0 })
  end

  def ins(*ints)
    CAFrame.new("a" => CA_INT32(ints), "b" => CA_FLOAT64(ints.map { |v| v.to_f }))
  end

  def test_splice_replaces_span_with_more_rows
    df = mk
    df[2..3] = ins(100, 101, 102)   # 2 rows -> 3 rows
    assert_equal 7, df.nrow
    assert_equal [0, 1, 100, 101, 102, 4, 5], df["a"].to_a
  end

  def test_splice_replaces_span_with_fewer_rows
    df = mk
    df[1..4] = ins(99)              # 4 rows -> 1 row
    assert_equal 3, df.nrow
    assert_equal [0, 99, 5], df["a"].to_a
  end

  def test_splice_at_head
    df = mk
    df[0...0] = ins(100, 101)       # empty span -> insert at head
    assert_equal [100, 101, 0, 1, 2, 3, 4, 5], df["a"].to_a
  end

  def test_splice_at_tail
    df = mk
    df[6...6] = ins(100, 101)       # empty span -> append at tail
    assert_equal [0, 1, 2, 3, 4, 5, 100, 101], df["a"].to_a
  end

  def test_splice_single_row_key
    df = mk
    df[2] = ins(100, 101, 102)      # single row -> 3 rows
    assert_equal [0, 1, 100, 101, 102, 3, 4, 5], df["a"].to_a
  end

  def test_splice_empty_frame_deletes_span
    df = mk
    empty = CAFrame.new("a" => CArray.int32(0), "b" => CArray.float64(0))
    df[1..2] = empty
    assert_equal [0, 3, 4, 5], df["a"].to_a
  end

  def test_splice_dtype_mismatch_raises
    # splice routes each column through CArray.meld, which is a view
    # constructor requiring same dtype across pieces.  Silent promotion here
    # would hide schema drift (e.g. an int column silently becoming float).
    # Callers with genuinely mixed-dtype inputs cast beforehand.
    df = mk   # b is float64, a is int32
    assert_raise(ArgumentError) {
      df[2..2] = CAFrame.new("a" => CA_FLOAT64([1.5]), "b" => CA_FLOAT64([9.0]))
    }
  end

  def test_splice_rhs_is_snapshot_not_view
    # df1[...] = df2 is a value assignment: subsequent writes to df1's
    # spliced middle segment must NOT propagate into df2 (which is only
    # supplying the values).  splice_rows snapshots each RHS column via
    # +.copy+, so the CAMeld middle parent is a fresh entity.
    df1 = CAFrame.new("a" => CA_INT32([0, 1, 2, 3, 4]))
    df2 = CAFrame.new("a" => CA_INT32([10, 20]))
    df1[2..3] = df2
    assert_equal [0, 1, 10, 20, 4], df1["a"].to_a
    # Write to the spliced middle segment in df1; df2 must stay intact.
    df1["a"][2] = 999
    assert_equal 999,        df1["a"][2]
    assert_equal [10, 20],   df2["a"].to_a
  end

  def test_splice_step1_arith_seq_is_contiguous
    df = mk
    df[(1..3).step(1)] = ins(100, 101)
    assert_equal [0, 100, 101, 4, 5], df["a"].to_a
  end

  def test_splice_negative_range
    # scan_index normalises the negative endpoints; -2..-1 is the last two rows.
    df = mk
    df[-2..-1] = ins(77)
    assert_equal [0, 1, 2, 3, 77], df["a"].to_a
  end

  def test_splice_block_array_form
    # [start, count] is a contiguous BLOCK: start 2, count 3 -> rows 2, 3, 4.
    df = mk
    df[[2, 3]] = ins(50, 51)
    assert_equal [0, 1, 50, 51, 5], df["a"].to_a
  end

  def test_splice_out_of_range_raises
    df = mk
    assert_raise(IndexError) { df[7..8] = ins(1) }
  end

  def test_splice_strided_slice_raises
    df = mk
    assert_raise(ArgumentError) { df[(0..4).step(2)] = ins(1, 2) }
  end

  def test_splice_boolean_selector_raises
    df = mk
    assert_raise(ArgumentError) { df[df["a"].gt(2)] = ins(1, 2) }
  end

  def test_splice_column_mismatch_raises
    df = mk
    assert_raise(ArgumentError) { df[0..1] = CAFrame.new("a" => CA_INT32([9])) }
  end
end

class TestCAFrameRowSpliceIndex < Test::Unit::TestCase
  def indexed
    CAFrame.new("a" => CA_INT32([1, 2, 3, 4]), index: CA_OBJECT(["w", "x", "y", "z"]))
  end

  def test_splice_weaves_the_index
    df  = indexed
    ins = CAFrame.new("a" => CA_INT32([90, 91]), index: CA_OBJECT(["p", "q"]))
    df[1..2] = ins
    assert_equal [1, 90, 91, 4], df["a"].to_a
    assert_equal ["w", "p", "q", "z"], df.index.to_a
  end

  def test_splice_without_index_on_indexed_target_raises
    df  = indexed
    ins = CAFrame.new("a" => CA_INT32([90, 91]))   # no index
    assert_raise(ArgumentError) { df[1..2] = ins }
  end
end

class TestCAFrameRowAssignErrors < Test::Unit::TestCase
  def mk
    CAFrame.new("a" => CArray.int32(4).seq(0))
  end

  def test_non_frame_non_sentinel_value_raises
    assert_raise(ArgumentError) { mk[0..1] = 5 }
  end
end

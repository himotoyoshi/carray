# spec_ai/test_segment.rb
#
# CArray.segment_offsets / CArray.segment_index convert between the
# representations of a flat sequence cut into consecutive segments:
# lengths (one count per segment), offsets (every boundary, k+1), and
# the segment index (which segment each element belongs to).
#
# Pinned here:
#
#   * the conversions and their round trip, against `seq.repeat` as the
#     reference for the segment index;
#   * the edges a hand-written prefix sum had to branch around: no
#     segments, no elements, zero lengths at either end;
#   * offsets that do not start at 0 (the offsets of a cut-out range);
#   * exactness past 2**53, which a float64 cumsum loses;
#   * the refusals: negative lengths, decreasing offsets, non-integers,
#     masked cells, and the keyword contract.

require "test/unit"
require "carray"

class TestSegment < Test::Unit::TestCase

  def test_offsets_from_lengths
    o = CArray.segment_offsets(lengths: CA_INT64([2, 0, 3]))
    assert_equal(CA_INT64, o.data_type)
    assert_equal([0, 2, 2, 5], o.to_a)
  end

  def test_index_from_lengths_and_offsets
    assert_equal([0, 0, 2, 2, 2], CArray.segment_index(lengths: [2, 0, 3]).to_a)
    assert_equal([0, 0, 2, 2, 2], CArray.segment_index(offsets: [0, 2, 2, 5]).to_a)
  end

  def test_offsets_need_not_start_at_zero
    assert_equal([0, 0, 2, 2, 2], CArray.segment_index(offsets: [4, 6, 6, 9]).to_a)
  end

  def test_matches_repeat_and_round_trips
    srand(7)
    200.times do
      k    = rand(0..20)
      lens = CA_INT64(Array.new(k) { rand(0..4) })
      idx  = CArray.segment_index(lengths: lens)
      assert_equal(CArray.int64(k).seq.repeat(lens).to_a, idx.to_a)
      offs = CArray.segment_offsets(lengths: lens)
      assert_equal(idx.to_a, CArray.segment_index(offsets: offs).to_a)
    end
  end

  def test_edges
    assert_equal([0], CArray.segment_offsets(lengths: CArray.int64(0)).to_a)
    assert_equal([], CArray.segment_index(lengths: CArray.int64(0)).to_a)
    assert_equal([], CArray.segment_index(offsets: [7]).to_a)
    assert_equal([0, 0, 0], CArray.segment_offsets(lengths: [0, 0]).to_a)
    assert_equal([1, 1, 1], CArray.segment_index(lengths: [0, 3, 0]).to_a)
  end

  def test_exact_past_2_pow_53
    big = 2**53 + 1
    assert_equal([0, big], CArray.segment_offsets(lengths: CA_INT64([big])).to_a)
  end

  def test_accepts_any_integer_or_boolean_and_views
    assert_equal([0, 1, 3], CArray.segment_offsets(lengths: CA_UINT32([1, 2])).to_a)
    assert_equal([0, 1, 1, 2],
                 CArray.segment_offsets(lengths: CA_INT32([1, 0, 1]).gt(0)).to_a)
    view = CArray.int64(10).seq[2..4]
    assert_equal([0, 0, 1, 1, 1, 2, 2, 2, 2],
                 CArray.segment_index(lengths: view).to_a)
    grid = CArray.int64(4).seq.reshape(2, 2)
    assert_equal([0, 0, 1, 3, 6], CArray.segment_offsets(lengths: grid).to_a)
  end

  def test_refusals
    assert_raise(ArgumentError) { CArray.segment_offsets(lengths: [1, -1]) }
    assert_raise(ArgumentError) { CArray.segment_index(offsets: [0, 3, 2]) }
    assert_raise(ArgumentError) { CArray.segment_index(offsets: []) }
    assert_raise(CArray::DataTypeError) { CArray.segment_offsets(lengths: CA_FLOAT64([1])) }
    assert_raise(ArgumentError) { CArray.segment_offsets(lengths: [1.0]) }
    assert_raise(TypeError) { CArray.segment_index(offsets: "x") }
    assert_raise(RangeError) { CArray.segment_offsets(lengths: [2**62, 2**62]) }
  end

  def test_masked_cells_refused
    lengths = CA_INT64([1, 2])
    lengths[0] = UNDEF
    assert_raise(ArgumentError) { CArray.segment_offsets(lengths: lengths) }
    offsets = CA_INT64([0, 2])
    offsets[0] = UNDEF
    assert_raise(ArgumentError) { CArray.segment_index(offsets: offsets) }
  end

  def test_keywords
    assert_raise(ArgumentError) { CArray.segment_index }
    assert_raise(ArgumentError) { CArray.segment_index(lengths: [1], offsets: [0, 1]) }
    assert_raise(ArgumentError) { CArray.segment_offsets(offsets: [0]) }
  end

end

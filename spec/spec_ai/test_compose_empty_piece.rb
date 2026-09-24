# Regression: the eager ragged paste (concatenate / mosaic) must accept a
# zero-length piece.
#
# __ragged_paste writes each piece with CArray#paste, which asked its
# destination for the window offset...(offset + src.shape[i]).  A piece of
# length zero asks for an empty range, and CAWindow rejects one ("invalid
# size for 0-th dimension"), so concatenating an empty slice raised
# IndexError -- even though concatenate is the ragged verb and CArray.meld
# (its view counterpart) took an empty piece without complaint.
#
# paste now returns early for a source that covers no cell; there is
# nothing to write, so the empty window is never asked for.

require 'test/unit'
require 'carray'

class TestComposeEmptyPiece < Test::Unit::TestCase

  def setup
    @a = CArray.int32(5) { |i| i }
  end

  def test_leading_empty_piece
    assert_equal [0, 1, 2, 3, 4], CArray.concatenate([CArray.int32(0), @a]).to_a
  end

  def test_trailing_empty_piece
    assert_equal [0, 1, 2, 3, 4], CArray.concatenate([@a, CArray.int32(0)]).to_a
  end

  def test_empty_piece_from_an_empty_slice
    assert_equal [1, 2], CArray.concatenate([@a[0...0], @a[1..2]]).to_a
  end

  def test_every_piece_empty_gives_a_zero_length_result
    r = CArray.concatenate([CArray.int32(0), CArray.int32(0)])
    assert_equal [0], r.shape
  end

  def test_two_dimensional_empty_piece_keeps_the_non_tile_axis
    r = CArray.concatenate([CArray.int32(0, 3), CArray.int32(2, 3) { 1 }], axis: 0)
    assert_equal [2, 3], r.shape
    assert_equal [[1, 1, 1], [1, 1, 1]], r.to_a
  end

  def test_mosaic_takes_an_empty_tile
    assert_equal [0, 1, 2, 3, 4], CArray.mosaic([CArray.int32(0), @a], [2]).to_a
  end

  def test_instance_form
    assert_equal [0, 1, 2, 3, 4], @a.concatenate(CArray.int32(0)).to_a
  end

  def test_paste_of_an_empty_source_is_a_no_op
    dst = CArray.int32(5) { |i| i }
    assert_equal [0, 1, 2, 3, 4], dst.paste([2], CArray.int32(0)).to_a
  end

end

# frozen_string_literal: true
#
# CArray#split (3.0 breaking)
#
# Pins:
#   - axis: keyword (single Integer only; multi-axis Array rejected)
#   - returns a Ruby Array of (ndim-1)-D slices
#   - slices are writable CABlock views (mutating a slice mutates self)
#   - exact inverse of CArray.stack: stack(a.split(axis: k), axis: k) == a

require "test/unit"
require "carray"

class TestSplitAxis < Test::Unit::TestCase
  def setup
    @a = CA_INT([[1, 2, 3], [4, 5, 6], [7, 8, 9]])
  end

  def test_axis_single_rows
    pieces = @a.split(axis: 0)
    assert_instance_of Array, pieces
    assert_equal 3, pieces.size
    assert_equal [1, 2, 3], pieces[0].to_a
    assert_equal [4, 5, 6], pieces[1].to_a
    assert_equal [7, 8, 9], pieces[2].to_a
  end

  def test_axis_single_cols
    pieces = @a.split(axis: 1)
    assert_equal 3, pieces.size
    assert_equal [1, 4, 7], pieces[0].to_a
    assert_equal [2, 5, 8], pieces[1].to_a
    assert_equal [3, 6, 9], pieces[2].to_a
  end

  def test_multi_axis_array_rejected
    assert_raise(ArgumentError) { @a.split(axis: [0, 1]) }
  end

  def test_pieces_are_writable_views
    pieces = @a.split(axis: 0)
    assert_kind_of CArray, pieces[0]
    pieces[0][1] = 99
    assert_equal [[1, 99, 3], [4, 5, 6], [7, 8, 9]], @a.to_a
  end

  def test_positional_argv_raises
    assert_raise(ArgumentError) { @a.split(0) }
  end

  def test_axis_required
    assert_raise(ArgumentError) { @a.split }
  end

  def test_3d_partial_split
    a3 = CArray.int32(2, 3, 4) { |i, j, k| 100 * i + 10 * j + k }
    pieces = a3.split(axis: 0)
    assert_equal 2, pieces.size
    assert_equal [3, 4], pieces[0].shape
    assert_equal a3[0, nil, nil].to_a, pieces[0].to_a
  end

  def test_inverse_of_stack
    [0, 1].each do |k|
      assert_equal @a.to_a, CArray.stack(@a.split(axis: k), axis: k).to_a
    end
  end
end

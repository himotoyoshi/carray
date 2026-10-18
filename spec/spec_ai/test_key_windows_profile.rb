# frozen_string_literal: true
#
# Windows on a key over a value of several columns (each row a profile,
# shape [N, ...]) reduce each trailing column over the same windows and lay
# the answers in the value's trailing shape, as a group reduces a profile
# column along the rows.  Before, the value had to have one cell per row.

require "test/unit"
require "carray"

class TestKeyWindowsProfile < Test::Unit::TestCase

  KEY = CA_DOUBLE([0, 1, 2, 3, 5, Float::NAN])

  def value
    v = CArray.float64(6, 2, 3) { |i, j, k| i * 10 + j * 3 + k }
    v[2, 1, 1] = UNDEF
    v
  end

  def per_column (op, *args)
    flat = value.reshape(6, 6)
    (0...6).map { |c| flat[nil, c].windows(on: KEY, before: 1.5).public_send(op, *args).to_a }
  end

  def same (a, b)
    a == b || (a.is_a?(Float) && b.is_a?(Float) && a.nan? && b.nan?)
  end

  def test_every_reduction_matches_the_columns_one_by_one
    w = value.windows(on: KEY, before: 1.5)
    %i[sum mean min max median count first last nunique min_index max_addr variance].each do |op|
      got = w.public_send(op)
      assert_equal [6, 2, 3], got.shape, op.to_s
      flat = got.reshape(6, 6)
      per_column(op).each_with_index do |col, c|
        assert flat[nil, c].to_a.zip(col).all? { |a, b| same(a, b) }, "#{op} column #{c}"
      end
    end
  end

  def test_answers_in_two_and_weights
    w = value.windows(on: KEY, before: 1.5)
    assert_equal [[6, 2, 3], [6, 2, 3]], w.minmax.map(&:shape)
    assert_equal [6, 2, 3], w.percentile(50).shape
    assert_equal [6, 2, 3], w.wsum(CA_DOUBLE([1, 2, 1, 1, 1, 1])).shape
  end

  def test_each_yields_the_rows_of_a_window
    pieces = value.windows(on: KEY, before: 1.5).each.to_a
    assert_equal 6, pieces.size
    assert pieces.all? { |p| p.ndim == 3 && p.shape[1..] == [2, 3] }
    assert_equal [0, 2, 3], pieces.last.shape                # the NaN key has no window
  end

  def test_a_block_fold_is_not_defined_over_several_columns
    assert_raise(NotImplementedError) { value.windows(on: KEY, before: 1.5).reduce { |x| x } }
  end

end

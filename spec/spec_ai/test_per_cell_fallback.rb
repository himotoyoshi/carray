# CArray.per_cell -- the interpreted form.
#
# per_cell is where an array algorithm is written: a recurrence, a stencil, a
# reduction.  The core carries the loop so that code written that way runs
# wherever CArray does; installing carray-jit replaces the method with one
# that compiles the block.
#
# The property under test is that the loop runs the extent it was given, in
# the order it was given -- which is what lets the compiled form be checked
# against this one, and what keeps a downward loop from silently running the
# other way.

require 'test/unit'
require 'carray'

class TestPerCellFallback < Test::Unit::TestCase

  # The file backing per_cell is autoloaded, so nothing pays for it until a
  # kernel is actually written.
  def test_the_method_file_is_not_loaded_until_it_is_called
    root = File.expand_path("../..", __dir__)
    script = 'require "carray"; ' \
             'print $LOADED_FEATURES.grep(%r{methods/per_cell}).size'
    output = IO.popen([RbConfig.ruby, "-I#{root}/lib", "-I#{root}/ext",
                       "-e", script], &:read)
    assert_equal "0", output
  end

  def test_a_recurrence
    x = 0.5
    values = CArray.double(24)
    values[0] = 1.0
    values[1] = x
    CArray.per_cell(2...24) { |i|
      w  = x * values[i-1]
      wy = w - values[i-2]
      values[i] = wy + w - wy/i
    }

    expected = Array.new(24, 0.0)
    expected[0] = 1.0
    expected[1] = x
    (2...24).each { |i|
      w = x * expected[i-1]
      wy = w - expected[i-2]
      expected[i] = wy + w - wy/i
    }
    24.times { |i| assert_equal expected[i], values[i] }
  end

  # A downward loop is written downward, so the loop here needs no analysis to
  # run it the right way round.
  def test_a_downward_loop
    n = 8
    upper = CArray.double(n).seq(1)
    right = CArray.double(n).seq(1)
    solution = CArray.double(n)
    solution[n-1] = 1.0
    CArray.per_cell((n-2).step(0, -1)) { |i|
      solution[i] = right[i] - upper[i] * solution[i+1]
    }

    expected = Array.new(n, 0.0)
    expected[n-1] = 1.0
    (n-2).step(0, -1) { |i| expected[i] = right[i] - upper[i] * expected[i+1] }
    n.times { |i| assert_equal expected[i], solution[i] }
  end

  def test_two_indices
    rows, columns = 3, 4
    source = CArray.double(rows, columns).seq(1)
    result = CArray.double(rows, columns)
    CArray.per_cell(rows, columns) { |i, j| result[i, j] = source[i, j] * 2.0 }
    assert_equal (source * 2.0).to_a, result.to_a
  end

  def test_a_reduction
    rows, columns = 3, 4
    source = CArray.double(rows, columns).seq(1)
    total = CArray.double(rows)
    CArray.per_cell(rows) { |i|
      accumulator = 0.0
      (0...columns).each { |j| accumulator = accumulator + source[i, j] }
      total[i] = accumulator
    }
    assert_equal source.sum(axis: 1).to_a, total.to_a
  end

  def test_an_extent_may_skip_cells
    values = CArray.double(10)
    source = CArray.double(10).seq(1)
    CArray.per_cell((0...10).step(2)) { |i| values[i] = source[i] * 10.0 }
    expected = Array.new(10, 0.0)
    (0...10).step(2) { |i| expected[i] = source[i] * 10.0 }
    assert_equal expected, values.to_a
  end

  # A block that names no index covers the arrays whole, in CArray's own
  # spelling for the whole of one.
  def test_the_whole_array_form
    a = CArray.double(2, 3).seq
    b = CArray.double(2, 3).seq(10)
    result = CArray.double(2, 3)
    CArray.per_cell { result[] = a[] + b[] * 2.0 }
    assert_equal (a + b * 2.0).to_a, result.to_a
  end

  def test_an_empty_extent_does_nothing
    values = CArray.double(4).seq
    CArray.per_cell(2...2) { |i| values[i] = -1.0 }
    assert_equal [0.0, 1.0, 2.0, 3.0], values.to_a
  end

  # ---- what it refuses ----

  def test_a_block_is_required
    assert_raise(ArgumentError) { CArray.per_cell(0...3) }
  end

  def test_an_index_without_an_extent
    values = CArray.double(4)
    assert_raise(ArgumentError) { CArray.per_cell { |i| values[i] = 1.0 } }
  end

  def test_an_extent_without_an_index
    a = CArray.double(4).seq
    result = CArray.double(4)
    assert_raise(ArgumentError) { CArray.per_cell(0...4) { result[] = a[] } }
  end

  def test_an_extent_of_the_wrong_kind
    values = CArray.double(4)
    assert_raise(ArgumentError) { CArray.per_cell("all") { |i| values[i] = 1.0 } }
  end

end

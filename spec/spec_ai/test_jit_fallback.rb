# CArray.per_cell and CArray.per_element -- the interpreted forms.
#
# These are where an array algorithm is written: a recurrence, a stencil, a
# reduction, an element-wise expression.  The core carries the loop so that
# code written that way runs wherever CArray does; installing carray-jit
# replaces both methods with ones that compile the block.
#
# Two properties are under test.  That the loop runs the extent it was given,
# in the order it was given -- which is what lets the compiled form be checked
# against this one, and what keeps a downward loop from silently running the
# other way.  And that the line between the two methods falls where carray-jit
# puts it: a block that names indices is per_cell's, a block that names none
# is per_element's, and each turns the other's block away.

require 'test/unit'
require 'carray'

class TestJitFallback < Test::Unit::TestCase

  # The file backing the two methods is autoloaded, so nothing pays for it
  # until a kernel is actually written.
  def test_the_method_file_is_not_loaded_until_it_is_called
    root = File.expand_path("../..", __dir__)
    script = 'require "carray"; ' \
             'print $LOADED_FEATURES.grep(%r{jit_fallback}).size'
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

  def test_an_empty_extent_does_nothing
    values = CArray.double(4).seq
    CArray.per_cell(2...2) { |i| values[i] = -1.0 }
    assert_equal [0.0, 1.0, 2.0, 3.0], values.to_a
  end

  # ---- per_element ----

  # A block that names no element covers the arrays whole, in CArray's own
  # spelling for the whole of one.  The left-hand side keeps its brackets
  # because Ruby needs them.
  def test_the_whole_array_spelling
    a = CArray.double(2, 3).seq
    b = CArray.double(2, 3).seq(10)
    result = CArray.double(2, 3)
    assert_nil CArray.per_element { result[] = a[] + b[] * 2.0 }
    assert_equal (a + b * 2.0).to_a, result.to_a
  end

  # The other spelling names the cells, one parameter per array, and returns
  # the result rather than being given somewhere to put it.
  def test_the_element_spelling
    a = CArray.double(4).seq(1)
    b = CArray.double(4).seq(10)
    sums = CArray.per_element(a, b) { |x, y| x + y }
    assert_equal (a + b).to_a, sums.to_a
  end

  def test_the_element_spelling_broadcasts
    rows = CArray.double(2, 1).seq(1)
    columns = CArray.double(1, 3).seq(10)
    result = CArray.per_element(rows, columns) { |x, y| x * y }
    assert_equal (rows * columns).to_a, result.to_a
  end

  # There is no expression to read here, so the result is typed from what the
  # block returned.
  def test_the_element_spelling_types_the_result_from_the_values
    values = CArray.double(4).seq(1)
    assert_equal CA_DOUBLE, CArray.per_element(values) { |x| x / 2.0 }.data_type
    assert_equal CA_INT64, CArray.per_element(values) { |x| x.to_i }.data_type
    assert_equal CA_BOOLEAN, CArray.per_element(values) { |x| x > 2.0 }.data_type
    assert_equal [false, false, true, true],
                 CArray.per_element(values) { |x| x > 2.0 }.to_a
  end

  # `reassociate:` licenses the compiler to take a reduction's accumulator out
  # of order.  Here the fold is a Ruby loop and runs as written, so the licence
  # has nothing to do -- but it is accepted, so that a program that asks the
  # compiler for one order or the other still runs without it.
  def test_the_reassociation_licence_is_accepted
    values = CArray.double(8).seq(1)
    [nil, false, true].each do |licence|
      box = CArray.double(1)
      arguments = licence.nil? ? {} : { :reassociate => licence }
      CArray.per_cell(1, **arguments) { |i|
        accumulator = 0.0
        (0...8).each { |j| accumulator = accumulator + values[j] }
        box[i] = accumulator
      }
      assert_equal 36.0, box[0], "reassociate: #{licence.inspect}"
    end
  end

  # ---- the line between the two ----

  def test_per_cell_refuses_a_block_that_names_no_index
    a = CArray.double(4).seq
    result = CArray.double(4)
    error = assert_raise(ArgumentError) { CArray.per_cell { result[] = a[] } }
    assert_match(/belongs to per_element/, error.message)
  end

  def test_per_element_refuses_a_block_with_no_arrays_to_bind
    values = CArray.double(4)
    error = assert_raise(ArgumentError) { CArray.per_element { |i| values[i] = 1.0 } }
    assert_match(/one array per parameter/, error.message)
  end

  # ---- what it refuses ----

  def test_a_block_is_required
    assert_raise(ArgumentError) { CArray.per_cell(0...3) }
    assert_raise(ArgumentError) { CArray.per_element }
  end

  def test_more_extents_than_indices
    values = CArray.double(4)
    assert_raise(ArgumentError) { CArray.per_cell(2, 2) { |i| values[i] = 1.0 } }
  end

  def test_arrays_given_to_the_whole_array_spelling
    a = CArray.double(4).seq
    result = CArray.double(4)
    assert_raise(ArgumentError) { CArray.per_element(a) { result[] = a[] } }
  end

  def test_more_elements_than_arrays
    a = CArray.double(4).seq
    assert_raise(ArgumentError) { CArray.per_element(a) { |x, y| x + y } }
  end

  def test_an_element_that_is_not_an_array
    a = CArray.double(4).seq
    assert_raise(ArgumentError) { CArray.per_element(a, 2.0) { |x, y| x + y } }
  end

  def test_an_index_without_an_extent
    values = CArray.double(4)
    assert_raise(ArgumentError) { CArray.per_cell { |i| values[i] = 1.0 } }
  end

  def test_an_extent_of_the_wrong_kind
    values = CArray.double(4)
    assert_raise(ArgumentError) { CArray.per_cell("all") { |i| values[i] = 1.0 } }
  end

end

# Inputs that used to pass and give a different answer from the one asked
# for: a data type name that merely begins with a known one, an exclusive
# range running backwards, an index array that is not one, and a window
# replicating the edge of an axis that has no edge.

require "carray"
require "test/unit"

class TestLooseInputRefused < Test::Unit::TestCase

  def test_a_type_name_must_match_whole
    %i[complex128 float16 int128 int4 doublet bytes objects int8_t].each do |name|
      assert_raise(ArgumentError, name.to_s) { CArray.new(name, [2]) }
      assert_raise(ArgumentError, name.to_s) { CArray.int32(2).to_type(name) }
    end
    assert_raise(ArgumentError) { CArray.new("int32\0x", [2]) }
  end

  def test_every_listed_type_name_still_reads
    { int: :int32, float: :float32, double: :float64, complex: :cmplx64,
      dcomplex: :cmplx128, byte: :uint8, short: :int16, cmplx128: :cmplx128,
      boolean: :boolean, object: :object, uint64: :uint64 }.each do |name, type|
      assert_equal CArray.data_type_name(type), CArray.new(name, [1]).data_type_name
    end
    assert_equal "fixlen", CArray.new(:fixlen, [1], :bytes => 3).data_type_name
  end

  def test_a_reversed_exclusive_range_is_as_reversed_as_the_inclusive_one
    a = CArray.int32(5).seq!
    assert_raise(ArgumentError) { a.window(3...2) }
    assert_raise(ArgumentError) { a.window(-2...-3) }
    assert_raise(ArgumentError) { a.window(3...1) }
    assert_raise(ArgumentError) { a.window((3...2) % 1) }
  end

  def test_a_forward_exclusive_range_keeps_its_cells
    a = CArray.int32(5).seq!
    assert_equal [1, 2], a.window(1...3).to_a
    assert_equal [], a.window(3...3).to_a
    assert_equal [], a.window(3..2).to_a
    assert_equal [1, 2], a.window((1...3) % 1).to_a
  end

  def test_nearest_has_no_cell_to_replicate_on_an_empty_axis
    assert_raise(IndexError) { CArray.float64(0).window(-1..1, bounds: :nearest) }
    assert_raise(IndexError) { CArray.object(0).window(0..0, bounds: :nearest) }
    assert_raise(IndexError) { CArray.float64(0, 2).window(0..1, 0..1, bounds: :nearest) }
  end

  def test_nearest_may_still_take_no_cells_of_an_empty_axis
    assert_equal [], CArray.float64(0).window(0...0, bounds: :nearest).to_a
  end

  def test_windows_over_an_empty_array_still_answer
    assert_equal 0, CArray.float64(0).windows(-1..1, bounds: :nearest).mean.elements
  end

  OBJECT_INDEX  = CA_OBJECT([1.5, 2])
  BOOLEAN_INDEX = CA_BOOLEAN([1, 0])

  def test_an_object_array_is_not_an_index_array
    [OBJECT_INDEX, CA_OBJECT([1, 2])].each do |idx|
      a = CArray.int32(4).seq!
      assert_raise(IndexError) { a.project(idx) }
      assert_raise(IndexError) { a.scatter_add!(idx, 9) }
      assert_raise(IndexError) { a.addr2index(idx) }
      assert_equal [0, 1, 2, 3], a.to_a
    end
  end

  def test_a_boolean_array_is_not_an_index_array
    a = CArray.int32(4).seq!
    assert_raise(IndexError) { a.project(BOOLEAN_INDEX) }
    assert_raise(IndexError) { a.scatter_add!(BOOLEAN_INDEX, 9) }
    assert_raise(IndexError) { a.addr2index(BOOLEAN_INDEX) }
    assert_equal [0, 1, 2, 3], a.to_a
  end

  def test_a_boolean_array_still_selects
    a = CArray.int32(2).seq!
    assert_equal [0], a[BOOLEAN_INDEX].to_a
    assert_equal [0, 1], CArray.int32(2, 2).seq![BOOLEAN_INDEX, nil].to_a.flatten
  end
end

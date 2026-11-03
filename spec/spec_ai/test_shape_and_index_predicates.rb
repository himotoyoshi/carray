# spec_ai/test_shape_and_index_predicates.rb
#
# same_shape? looks at shapes only; valid_index? and valid_addr? say whether
# self[...] names a cell.

require "test/unit"
require "carray"

class TestShapeAndIndexPredicates < Test::Unit::TestCase

  def test_same_shape_whatever_the_data_types
    time = CArray.time(["2024-01-01", "2024-01-02"], unit: :D)
    faces = [time,
             CArray.const_string(%w[ab cd]),
             CArray.fixlen_string(%w[ab cd]),
             CArray.fixlen(2, bytes: 4),
             CA_OBJECT(%w[a b]).categorize]
    faces.each do |x|
      assert_true  x.same_shape?(CArray.int32(2)), x.class.name
      assert_false x.same_shape?(CArray.int32(3)), x.class.name
      assert_true  CArray.int32(2).same_shape?(x), x.class.name
      assert_false CArray.int32(3).same_shape?(x), x.class.name
    end
  end

  def test_same_shape_with_what_is_not_a_carray
    [CArray.int32(2), CArray.fixlen(2, bytes: 4)].each do |x|
      assert_true  x.same_shape?([1, 2])
      assert_false x.same_shape?([1, 2, 3])
      assert_true  x.same_shape?([Object.new, "s"])
    end
    assert_true  CArray.int32(2, 2).same_shape?([[1, 2], [3, 4]])
    assert_false CArray.int32(2, 2).same_shape?([1, 2, 3, 4])
    assert_true  CArray.int32(2, 2).same_shape?(1)
  end

  def test_valid_index_agrees_with_the_cell_access
    a = CArray.int32(3, 4)
    [[2, 3], [-3, -4], [3, 0], [-4, 0], [0, 4], [2**70, 0], [0, -2**70]].each do |i, j|
      answer = begin a[i, j]; true; rescue IndexError; false; end
      assert_equal answer, a.valid_index?(i, j), [i, j].inspect
    end
  end

  def test_valid_addr_agrees_with_the_cell_access
    a = CArray.int32(3, 4)
    [11, -12, 12, -13, 2**70, -2**70].each do |i|
      answer = begin a[i]; true; rescue IndexError; false; end
      assert_equal answer, a.valid_addr?(i), i.to_s
    end
    assert_false CArray.int32(0).valid_addr?(0)
  end

  def test_what_is_not_an_integer_is_refused
    a = CArray.int32(3, 4)
    [1.5, 1.0, 1r, nil, "1"].each do |x|
      assert_raise(TypeError, x.inspect) { a.valid_index?(x, 0) }
      assert_raise(TypeError, x.inspect) { a.valid_addr?(x) }
    end
  end
end

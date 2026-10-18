require 'test/unit'
require 'carray'

# CArray#where gives the flat addresses of the non-zero (or true) cells.
# An integer, float or complex array selects its non-zero cells; any
# other non-boolean array is cast to boolean, which takes only 0 / 1 /
# true / false.  Masked cells are never selected.
class TestWhere < Test::Unit::TestCase

  def test_boolean
    m = CA_BOOLEAN([false, true, false, true])
    assert_equal [1, 3], m.where.to_a
    assert_equal :int64, m.where.data_type
  end

  def test_integer_selects_non_zero
    assert_equal [1, 3], CArray.int32(5) { [0, 1, 0, 2, 0] }.where.to_a
    assert_equal [0, 2], CA_INT8([-1, 0, 127]).where.to_a
    assert_equal [1], CA_UINT8([0, 255]).where.to_a
  end

  def test_float_selects_non_zero_and_nan
    a = CArray.float64(5) { [0.0, -0.0, Float::NAN, 2.5, -1.0] }
    assert_equal [2, 3, 4], a.where.to_a
    assert_equal [1], CA_FLOAT32([0.0, 0.5]).where.to_a
  end

  def test_complex_selects_non_zero
    assert_equal [1, 2], CArray.cmplx128(3) { [0, 1i, 2] }.where.to_a
  end

  def test_masked_cells_are_not_selected
    a = CA_INT32([0, 3, 4, 5])
    a[1] = UNDEF
    assert_equal [2, 3], a.where.to_a
    b = CA_BOOLEAN([true, true, false])
    b[0] = UNDEF
    assert_equal [1], b.where.to_a
  end

  def test_empty_and_none_selected
    assert_equal [], CArray.int32(0).where.to_a
    assert_equal [], CArray.float64(4).fill(0.0).where.to_a
    assert_equal [], CArray.boolean(3).fill(false).where.to_a
  end

  def test_trailing_and_leading_selection
    srand(7)
    [1, 2, 7, 64, 1001].each do |n|
      [Array.new(n) { rand < 0.5 }, Array.new(n) { |i| i == n - 1 },
       Array.new(n) { |i| i == 0 }, Array.new(n, true)].each do |b|
        m = CArray.boolean(n)
        m[] = b.map { |v| v ? 1 : 0 }
        assert_equal (0...n).select { |i| b[i] }, m.where.to_a
      end
    end
  end

  def test_view_and_lazy
    a = CArray.int32(3, 4).seq!
    assert_equal [1, 3, 5, 7, 9, 11], (a % 2).where.to_a
    assert_equal [1, 2, 3], a[0, nil].where.to_a
    assert_equal (0...12).to_a - [4], (a.lazy - 4).where.to_a
  end

  def test_object_keeps_the_boolean_cast
    assert_equal [1, 2], CA_OBJECT([0, 1, true]).where.to_a
    assert_raise(CArray::DataTypeError) { CA_OBJECT([0, 2]).where }
  end

  def test_face_keeps_the_boolean_cast
    assert_raise(TypeError) { CArray.time(["2024-01-01"]).where }
  end
end

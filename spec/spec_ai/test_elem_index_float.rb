require "test/unit"
require "carray"

# elem_* reads an index as `[]` reads a key: an Integer, or a Float with no
# fraction.
class TestElemIndexFloat < Test::Unit::TestCase

  def test_a_float_with_no_fraction_is_an_index
    a = CArray.int32(5).seq!
    assert_equal a[1.0], a.elem_fetch(1.0)
    b = CArray.int32(2, 3).seq!
    assert_equal b[1.0, 2.0], b.elem_fetch([1.0, 2.0])
    a.elem_store(3.0, 9)
    assert_equal 9, a[3]
  end

  def test_a_fraction_is_refused_as_by_brackets
    a = CArray.int32(5).seq!
    assert_raise(IndexError) { a[1.5] }
    assert_raise(IndexError) { a.elem_fetch(1.5) }
    assert_raise(IndexError) { a.elem_fetch(Float::NAN) }
  end

  def test_an_integer_past_int64_is_out_of_range
    assert_raise(IndexError) { CArray.int32(5).elem_fetch(2**70) }
  end

end

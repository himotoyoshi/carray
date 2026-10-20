require "test/unit"
require "carray"

# fill on an empty array checks the value as an assignment does; it took
# any value because there was no cell to put it in.
class TestFillEmptyValue < Test::Unit::TestCase

  def test_a_value_no_cell_could_hold
    e = CArray.uint8(0)
    assert_raise(RangeError)    { e.fill(300) }
    assert_raise(ArgumentError) { e.fill("x") }
    assert_raise(RangeError)    { e[] = 300 }
  end

  def test_a_value_a_cell_could_hold
    assert_equal [], CArray.uint8(0).fill(3).to_a
    assert_equal [], CArray.uint8(0).fill(UNDEF).to_a
    assert_equal [2, 0], CArray.int32(2, 0).fill(1).shape
  end

end

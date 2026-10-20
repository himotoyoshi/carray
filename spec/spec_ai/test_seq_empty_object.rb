require "test/unit"
require "carray"

# seq on an empty object array has no first cell; it wrote one anyway,
# past the end of the buffer.
class TestSeqEmptyObject < Test::Unit::TestCase

  def test_seq_of_an_empty_object_array_writes_nothing
    assert_equal [], CArray.object(0).seq(0, 1).to_a
    assert_equal [], CArray.object(0).seq("a", :succ).to_a
    assert_equal [], CArray.arange(0, -0.5).to_a
  end

end

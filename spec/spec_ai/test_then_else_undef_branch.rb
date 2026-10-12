require "test/unit"
require "carray"

# An UNDEF branch of then_else masks its cells and leaves the data type to
# the other branch.
class TestThenElseUndefBranch < Test::Unit::TestCase

  def test_type_from_the_other_branch
    b = CA_FLOAT64([0.5, 2, 3])
    c = b > 1.0
    r = c.then_else(b, UNDEF)
    assert_equal :float64, r.data_type
    assert_equal [UNDEF, 2.0, 3.0], r.to_a
    assert_equal [0.5, UNDEF, UNDEF], c.then_else(UNDEF, b).to_a
    assert_equal :int32, c.then_else(CA_INT32([1, 2, 3]), UNDEF).data_type
    assert_equal [UNDEF, 1.5, 1.5], c.then_else(1.5, UNDEF).to_a
  end

  def test_both_undef
    assert_equal [UNDEF, UNDEF], CA_BOOLEAN([1, 0]).then_else(UNDEF, UNDEF).to_a
  end
end

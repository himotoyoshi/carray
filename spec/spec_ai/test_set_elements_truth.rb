require "test/unit"
require "carray"

# true and false in a Ruby Array given as a set of values (locate_addr,
# intersection, union, difference) are the numbers 1 and 0 beside a
# numeric array, as they are to an operator and to is_in; the answers are
# the ones a CA_BOOLEAN set gives.
class TestSetElementsTruth < Test::Unit::TestCase

  def setup
    @i = CA_INT32([0, 1, 2, 3])
  end

  def test_locate_addr
    assert_equal [1, 0, UNDEF, UNDEF], @i.locate_addr([true, false]).to_a
    assert_equal @i.locate_addr(CA_BOOLEAN([true, false])).to_a,
                 @i.locate_addr([true, false]).to_a
    assert_equal [UNDEF, 0], CA_FLOAT64([0, 1]).locate_addr([true]).to_a
  end

  def test_set_operations
    assert_equal [1], @i.intersection([true]).to_a
    assert_equal [2, 3], @i.difference([true, false]).to_a
    assert_equal "int32", @i.union([true]).data_type_name
  end

  def test_a_boolean_array_keeps_them_as_booleans
    b = CA_BOOLEAN([true, false])
    assert_equal [UNDEF, 0], b.locate_addr([false]).to_a
    assert_equal [true], b.intersection([true]).to_a
  end

end

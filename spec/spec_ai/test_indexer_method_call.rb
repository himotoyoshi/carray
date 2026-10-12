require "test/unit"
require "carray"

# a[:m, x] is a[a.m(x)]: the method is called as a call written out would
# reach it, so only a public method runs.
class TestIndexerMethodCall < Test::Unit::TestCase

  def test_public_methods_select
    a = CA_INT32([0, 1, 2, 0])
    a[1] = UNDEF
    assert_equal [0, 0], a[:eq, 0].to_a
    assert_equal [0, 2, 0], a[:is_not_masked].to_a
    a[:eq, 0] = 9
    assert_equal [9, UNDEF, 2, 9], a.to_a
  end

  def test_private_methods_are_not_called
    a = CA_INT32([0, 1, 2])
    assert_raise(NoMethodError) { a[:puts] }
    assert_raise(NoMethodError) { a[:initialize] }
    assert_raise(NoMethodError) { a[:puts] = 1 }
    assert_equal [0, 1, 2], a.to_a
  end

  def test_a_record_array_calls_its_methods_the_same_way
    st = CArray.struct { int32 :w }
    r = CARecord.new(st, 3)
    r["w"][] = [1, 2, 3]
    r[1] = UNDEF
    assert_equal [1, 3], r[:is_not_masked]["w"].to_a
    assert_raise(NoMethodError) { r[:puts] }
  end

end

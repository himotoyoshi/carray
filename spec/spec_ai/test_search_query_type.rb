require "test/unit"
require "carray"

# A search compares the query in the type it shares with the array, as
# `a.eq(q)` does: a Float or a wider CArray is not truncated to an integer
# array's type.  An Integer that does not fit an integer array is refused.
class TestSearchQueryType < Test::Unit::TestCase

  def test_float_query_on_an_integer_array
    i = CA_INT8([1, 3])
    assert_nil i.search(3.9)
    assert_nil i.bsearch(3.9)
    assert_equal 1, i.search(3.0)
    assert_equal 1, i.bsearch(3.0)
    assert_equal 1, i.search_nearest(2.6)
    assert_equal 1, i.search_nearest(2.4)     # 1.4 vs 0.6 -> 3
    assert_equal 0, i.search_nearest(1.9)
    assert_equal 1, i.search(2.9, 0.5)        # a Float query is a float comparison
  end

  def test_wider_carray_query
    i = CA_INT8([1, 3])
    assert_equal [UNDEF, 1], i.bsearch(CA_FLOAT64([3.9, 3.0])).to_a
    assert_equal [1], i.search_nearest(CA_FLOAT64([2.6])).to_a
    assert_equal [UNDEF], i.search(CA_INT64([259])).to_a   # not 3 = 259 mod 256
  end

  def test_integer_query_that_does_not_fit
    assert_raise(RangeError) { CA_INT8([1, 3]).search(1000) }
    assert_raise(RangeError) { CA_INT8([1, 3]).search_nearest(1000) }
  end

  def test_a_wider_float_query_array_is_not_rounded_to_the_reference
    g = CA_FLOAT32([0.1, 0.5, 2**24])
    assert_equal [UNDEF], g.search(CA_FLOAT64([2**24 + 1])).to_a
    assert_equal 0, CA_FLOAT32([0.1, 0.2]).search(0.1)
  end

  def test_mixed_sign_query_array_is_matched_by_value
    assert_equal [UNDEF, 1], CA_UINT8([255, 1]).search(CA_INT8([-1, 1])).to_a
    assert_equal [UNDEF, 0], CA_UINT8([1, 255]).bsearch(CA_INT8([-1, 1])).to_a
    assert_equal [UNDEF, 1], CA_UINT64([2**64 - 1, 1]).search(CA_INT64([-1, 1])).to_a
  end

  def test_an_infinite_query_finds_its_own_value_only
    inf = Float::INFINITY
    a = CA_FLOAT64([1.0, inf])
    assert_equal 1, a.search(inf)
    assert_nil a.search(-inf)
    assert_equal 1, a.search(inf, 0.0)
    assert_equal 1, a.search_nearest(inf)
    assert_equal 1, CA_OBJECT([1.0, inf]).search_nearest(inf)
    assert_equal 1, CA_FLOAT64([Float::NAN, 2.0]).search_nearest(1.0)
  end
end

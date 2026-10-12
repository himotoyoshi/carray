require "test/unit"
require "carray"

# A Float NaN in an object array is searched as it is in a float array:
# it sorts last for bsearch and is no distance for search_nearest.  An
# object refusal names the method that was called.
class TestSearchObjectNan < Test::Unit::TestCase

  def test_nan_in_an_object_array_is_searched_like_float
    nan = Float::NAN
    o = CA_OBJECT([1, 2r, 3.0, nan])
    f = CA_FLOAT64([1, 2, 3, nan])
    [3, 5, nan].each do |q|
      assert_equal f.bsearch(q), o.bsearch(q), "bsearch #{q}"
      assert_equal f.bsearch_addr(q), o.bsearch_addr(q), "bsearch_addr #{q}"
      assert_equal f.search_nearest(q), o.search_nearest(q), "search_nearest #{q}"
    end
    assert_nil CA_OBJECT([nan, nan]).search_nearest(1)
    assert_equal 2, CA_OBJECT([nan, 5, 2.0]).search_nearest(1)
  end

  def test_object_refusal_names_the_method
    e = assert_raise(CArray::DataTypeError) { CA_OBJECT(["a"]).search_nearest_addr("b") }
    assert_match(/\Asearch_nearest_addr: /, e.message)
    e = assert_raise(ArgumentError) { CA_OBJECT([1, "a"]).bsearch_addr(2) }
    assert_match(/\Absearch_addr: comparison/, e.message)
  end
end

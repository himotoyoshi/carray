require "test/unit"
require "carray"

# A Hash passed as a positional argument is an argument, as in Ruby 3: only
# keywords are options.  So a Hash can be the value searched for or counted
# in an object array, and `f({axis: 0})` is refused rather than read as
# `f(axis: 0)`.
class TestPositionalHashIsAValue < Test::Unit::TestCase

  def setup
    @o = CA_OBJECT([{a: 1}, {a: 2}, {a: 1}])
    @f = CArray.float64(3, 4).seq!
  end

  def test_a_hash_is_a_value_to_look_for
    assert_equal 0, @o.search({a: 1})
    assert_equal 1, @o.search_addr({a: 2})
    assert_equal 2, @o.count({a: 1})
    assert_equal 2, @o.count({a: 1}, axis: 0)
  end

  def test_a_positional_hash_is_not_read_as_keywords
    assert_raise(ArgumentError) { @f.sum({axis: 0}) }
    assert_raise(ArgumentError) { @f.median({axis: 0}) }
    assert_raise(ArgumentError) { @f.refer(:int32, [3, 8], {bytes: 4}) }
    assert_raise(ArgumentError) { @f.each_slab({axis: 0}) }
  end

  def test_keywords_still_work
    opts = {axis: 0}
    assert_equal [12.0, 15.0, 18.0, 21.0], @f.sum(**opts).to_a
    assert_equal [3, 8], @f.refer(:int32, [3, 8], bytes: 4).shape
    assert_equal [3, 3, 3, 3], @f.count(axis: 0).to_a
  end

  # The options carray passes to itself from C still arrive as options.
  def test_options_carray_passes_to_itself
    m = @f.copy
    m[0, 0] = UNDEF
    assert_equal [3, 4], m.value.shape
    assert_equal 5, @f.quantile.size
    assert_equal [12], m.sort_copy.shape
    assert_equal [1, 2, 0], CArray.sort_addr(CA_INT32([3, 1, 2])).to_a
    k = CA_INT32([[3, 1], [2, 4]])
    assert_equal [3, 4], k.max_by_key(k, axis: 0).to_a
  end

end

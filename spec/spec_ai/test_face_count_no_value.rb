require "test/unit"
require "carray"

# count with no value counts the cells that are not masked, as CArray#count
# does; CAConstString and CACategorical required a value.
class TestFaceCountNoValue < Test::Unit::TestCase

  def test_const_string
    c = CArray.const_string(["a", nil, "a"])
    assert_equal 2, c.count
    assert_equal 2, c.count("a")
  end

  def test_categorical
    x = CA_OBJECT(%w[a b a]); x[1] = UNDEF
    cat = x.categorize
    assert_equal 2, cat.count
    assert_equal 2, cat.count("a")
    assert_raise(ArgumentError) { cat.count(1, 2) }
  end

end

require "test/unit"
require "carray"

# A CScalar in a selection is a value, as it is for then_else.
class TestSelectionTakesACScalar < Test::Unit::TestCase

  def value (v)
    s = CScalar.new(:float64)
    s[0] = v
    s
  end

  def setup
    @a = CArray.float64(4).seq
    @cond = @a > 1
  end

  def test_replace_where
    assert_equal [0.0, 1.0, 9.0, 9.0], @a.replace_where(@cond, value(9.0)).to_a
  end

  def test_replace_where_with_a_masked_value
    assert_equal [0.0, 1.0, UNDEF, UNDEF], @a.replace_where(@cond, value(UNDEF)).to_a
  end

  def test_select
    got = CArray.select([@cond], [value(9.0)], default: -1.0)
    assert_equal [-1.0, -1.0, 9.0, 9.0], got.to_a
  end

  def test_select_with_a_masked_choice
    got = CArray.select([@cond], [value(UNDEF)], default: -1.0)
    assert_equal [-1.0, -1.0, UNDEF, UNDEF], got.to_a
  end
end

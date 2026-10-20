require "test/unit"
require "carray"

# str_index / rindex answer UNDEF in a cell that does not hold the
# substring; the nil String#index gives could not go into the int result
# and raised for the whole array.
class TestStrIndexNotFound < Test::Unit::TestCase

  def test_every_string_kind
    [CArray.string(%w[abc xyz]), CArray.const_string(%w[abc xyz]),
     CArray.fixlen_string(%w[abc xyz])].each do |a|
      assert_equal [1, UNDEF], a.str_index("b").to_a, a.class.name
      assert_equal [UNDEF, 2], a.rindex("z").to_a, a.class.name
    end
  end

end

require "test/unit"
require "carray"

class TestStringOperationKeepsTheSource < Test::Unit::TestCase

  def test_force_encoding_answers_with_new_strings
    a = CArray.string(CA_OBJECT(["abc", "de"]))
    got = a.force_encoding("BINARY")
    assert_equal [Encoding::BINARY] * 2, got.to_a.map(&:encoding)
    assert_equal [Encoding::UTF_8] * 2, a.to_a.map(&:encoding)
  end

  def test_force_encoding_of_frozen_cells
    a = CArray.const_string(["abc", "de"])
    assert_equal [Encoding::BINARY] * 2, a.force_encoding("BINARY").to_a.map(&:encoding)
  end
end

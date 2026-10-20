require "test/unit"
require "carray"

# The swap_bytes view names itself in inspect; it showed an internal number.
class TestSwapBytesInspect < Test::Unit::TestCase

  def test_names_the_operation
    v = CA_INT32([1]).swap_bytes
    assert_match(/\A#<CAMonOp swap_bytes\(/, v.inspect)
    assert_match(/\Aswap_bytes$/, v.dump_tree)
  end

end

require "test/unit"
require "carray"

# swap_bytes reads the same cells another way, as refer, bitarray and
# bitfield do, and carries the attributes as they do.  A computing view
# (abs) does not.
class TestAttributeSwapBytes < Test::Unit::TestCase

  def test_swap_bytes_carries
    a = CA_INT32([1, 2])
    a.set_attr(:units, "m")
    assert_equal({ "units" => "m" }, a.swap_bytes.attrs)
    assert_equal({ "units" => "m" }, a.swap_bytes.copy.attrs)
    assert_equal({ "units" => "m" }, a.refer(:int8, [8]).attrs)
    assert_equal({}, a.abs.attrs)
  end

end

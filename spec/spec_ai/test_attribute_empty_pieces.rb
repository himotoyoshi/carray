require "test/unit"
require "carray"

# An array with no cells has no say in which attributes a meld or a
# concatenation keeps, as a frame with no rows has none in CAFrame.meld.
class TestAttributeEmptyPieces < Test::Unit::TestCase

  def test_empty_pieces_are_left_out
    a = CA_INT32([1, 2]); a.set_attr(:units, "m")
    e = CArray.int32(0);  e.set_attr(:units, "s")
    f = CArray.int32(0)
    assert_equal({ "units" => "m" }, CArray.concatenate([a, e]).attrs)
    assert_equal({ "units" => "m" }, CArray.meld(a, e).attrs)
    assert_equal({ "units" => "m" }, CArray.meld(a, f).attrs)
  end

  def test_all_empty_still_agree_among_themselves
    g = CArray.int32(0); g.set_attr(:units, "q")
    assert_equal({ "units" => "q" }, CArray.meld(g, g).attrs)
    assert_equal({}, CArray.meld(CArray.int32(0), g).attrs)
  end

end

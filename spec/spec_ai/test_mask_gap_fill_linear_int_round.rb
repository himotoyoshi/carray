require "test/unit"
require "carray"

class TestMaskGapFillLinearIntegerRound < Test::Unit::TestCase
  def test_integer_takes_the_nearest_integer
    assert_equal [190, 240, 291, 341],
                 CA_INT64([190, UNDEF, UNDEF, 341]).strip_mask(method: :linear).to_a
  end

  def test_midpoints_round_away_from_zero
    assert_equal [0, 1, 1],   CA_INT64([0, UNDEF, 1]).strip_mask(method: :linear).to_a
    assert_equal [0, -1, -1], CA_INT64([0, UNDEF, -1]).strip_mask(method: :linear).to_a
  end

  def test_unsigned_stays_in_range
    assert_equal [250, 253, 255], CA_UINT8([250, UNDEF, 255]).strip_mask(method: :linear).to_a
  end

  def test_unmask_in_place_and_frame_fill
    a = CA_INT32([10, UNDEF, 13])
    a.unmask(method: :linear)
    assert_equal [10, 12, 13], a.to_a
    df = CAFrame.new({ "v" => CA_INT64([10, UNDEF, 13]) }, index: CA_FLOAT64([0, 1, 2]))
    df.fill("v", :linear)
    assert_equal [10, 12, 13], df["v"].to_a
  end
end

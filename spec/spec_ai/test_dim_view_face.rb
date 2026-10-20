require "test/unit"
require "carray"

# dim_view reorders axes, as transpose does, and keeps a Face; it gave a
# bare view of the storage.
class TestDimViewFace < Test::Unit::TestCase

  def test_a_time_stays_a_time
    t = CArray.time(["2024-01-01", "2024-01-02"], unit: :D).reshape(1, 2)
    v = t.dim_view(1)
    assert_kind_of CATime, v
    assert_equal [2, 1], v.shape
    assert_equal ["2024-01-01", "2024-01-02"], v.to_a.flatten.map(&:to_s)
  end

  def test_a_plain_array_is_unchanged
    assert_kind_of CATranspose, CArray.int32(2, 3).seq.dim_view(1)
  end

end

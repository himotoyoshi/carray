# spec_ai/test_windows_rank_limit.rb
#
# A window iterator views the windows through an array with one axis per
# window position and one per cell in the window: twice the source's rank.
# So windows reaches rank CA_RANK_MAX / 2 (8), and a source of higher rank
# is refused when the iterator is made, by windows and with the reason.

require "test/unit"
require "carray"

class TestWindowsRankLimit < Test::Unit::TestCase

  def test_the_highest_rank_windows_reaches
    n = CA_RANK_MAX / 2
    a = CArray.float64(*[2] * n).seq!
    assert_equal a.shape, a.windows(*[0..0] * n).sum.shape
    assert_equal a.to_a, a.windows(*[0..0] * n).sum.to_a
  end

  def test_a_higher_rank_is_refused_by_windows
    n = CA_RANK_MAX / 2 + 1
    a = CArray.float64(*[2] * n).seq!
    e = assert_raise(ArgumentError) { a.windows(*[0..0] * n) }
    assert_match(/\Awindows: /, e.message)
    assert_match(/rank #{n}/, e.message)
    assert_match(/#{CA_RANK_MAX / 2}/, e.message)
  end
end

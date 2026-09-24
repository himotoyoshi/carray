# Regression: the index walk behind each_with_index / map_with_index! must
# not grow the C stack per cell.
#
# rb_ca_index_walk built the yield argument vector with ALLOCA_N *inside*
# the innermost loop.  alloca releases at function exit, not per iteration,
# so the walk consumed (ndim + 1) VALUEs of C stack per cell: a long enough
# axis raised SystemStackError.  On an 8 MB main stack a 1-D array died
# around a million cells; on a Thread's smaller stack it died near a
# hundred thousand, which is where CArray#format (built on
# map_with_index!) was first seen to fail.
#
# Two million cells is 32 MB of the old growth -- past any plausible stack
# -- so these fail loudly if the buffer ever moves back inside the loop.

require 'test/unit'
require 'carray'

class TestIndexWalkLarge < Test::Unit::TestCase

  N = 2_000_000

  def test_each_with_index_over_a_long_axis
    seen = 0
    CArray.int32(N).each_with_index { |_v, _i| seen += 1 }
    assert_equal N, seen
  end

  def test_map_with_index_bang_over_a_long_axis
    a = CArray.int32(N).map_with_index! { |_v, i| i }
    assert_equal 0,     a[0]
    assert_equal N - 1, a[N - 1]
  end

  def test_each_index_over_a_long_axis
    seen = 0
    CArray.int32(N).each_index { |_i| seen += 1 }
    assert_equal N, seen
  end

  def test_format_over_a_long_axis
    s = CArray.float64(N) { |i| i * 0.5 }.format("%.1f")
    assert_equal "0.0", s[0]
    assert_equal Kernel.format("%.1f", (N - 1) * 0.5), s[N - 1]
  end

  # A Thread gets a smaller machine stack than the main one, so it is the
  # cheapest place to catch a regression: this used to die well under
  # 200_000 cells.
  def test_two_dimensional_walk_on_a_thread_stack
    n = 200_000
    ok = Thread.new do
      a = CArray.float64(n, 2) { |i, _j| i * 1.0 }
      a.map_with_index! { |_v, i, j| (i + j).to_f }
      a[n - 1, 1]
    end.value
    assert_equal (n - 1 + 1).to_f, ok
  end

end

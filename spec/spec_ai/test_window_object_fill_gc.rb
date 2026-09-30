# spec_ai/test_window_object_fill_gc.rb
#
# The fill value of a `window` / `shift` over an object array is a Ruby
# object the view keeps in its own buffer, so the view has to mark it:
# otherwise a GC frees it, and the out-of-range cells read whatever object
# took its slot.

require "test/unit"
require "carray"

class TestWindowObjectFillGC < Test::Unit::TestCase

  def churn
    5.times do
      GC.start
      20000.times { "q" * 41 }
    end
  end

  def fill
    "F" + "x" * 40          # long enough not to be embedded or shared
  end

  def setup
    @o = CArray.object(4) { |i| "v#{i}" }
  end

  def test_window
    w = @o.window(-2..5, fill_value: fill)
    churn
    assert_equal [fill, fill, "v0", "v1", "v2", "v3", fill, fill], w.to_a
  end

  def test_shift
    s = @o.shift(1, fill_value: fill)
    churn
    assert_equal [fill, "v0", "v1", "v2"], s.to_a
  end

  def test_dup_and_derived_views
    w = @o.window(-2..5, fill_value: fill)
    d = w.dup
    v = w[0..2]
    w = nil
    churn
    assert_equal [fill, fill, "v0"], d.to_a.first(3)
    assert_equal [fill, fill, "v0"], v.to_a
  end

end

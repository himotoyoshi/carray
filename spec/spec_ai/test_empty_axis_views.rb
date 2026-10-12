# spec_ai/test_empty_axis_views.rb
#
# `shift`, `roll`, `tile` and `window` over an array with a zero-length
# axis give an empty view, as `transpose`, `flip` and a block reference
# do.  They used to raise IndexError.  A window may also select nothing
# from a non-empty array (`a.window(0...0)`).

require "test/unit"
require "carray"

class TestEmptyAxisViews < Test::Unit::TestCase

  VIEWS = {
    shift:  [->(a) { a.shift(1, 0) },          [3, 0]],
    roll:   [->(a) { a.roll(1, 2) },           [3, 0]],
    tile:   [->(a) { a.tile(2, 3) },           [6, 0]],
    window: [->(a) { a.window(0..1, 0...0) },  [2, 0]],
  }

  def sources
    masked = CArray.int32(3, 0)
    masked.mask = 0
    { plain: CArray.int32(3, 0), masked: masked }
  end

  VIEWS.each do |name, (make, shape)|
    define_method("test_#{name}") do
      sources.each do |kind, a|
        v = make.(a)
        assert_equal shape, v.shape, "#{name} #{kind}"
        assert_equal [], v.to_a
        assert_equal shape, v.copy.shape
        assert_equal shape, v.dup.shape
        assert_equal 0.0, v.sum
        assert_equal [], v.is_masked.to_a
        assert_nothing_raised { v[] = 1 }
      end
    end
  end

  def test_one_dimensional
    e = CArray.int32(0)
    assert_equal [], e.shift(1).to_a
    assert_equal [], e.roll(1).to_a
    assert_equal [0], e.tile(3).shape
  end

  def test_window_that_selects_nothing
    assert_equal [], CArray.int32(4).seq!.window(0...0).to_a
  end

  def test_what_is_still_refused
    assert_raise(IndexError) { CArray.int32(4).tile(0) }          # zero repetitions
  end

end

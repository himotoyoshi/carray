require "test/unit"
require "carray"

# A length, a count, an offset or a shift given to a view is an Integer: a
# Float is refused naming the method and the argument, not truncated.

class TestSizeArgumentsAreIntegers < Test::Unit::TestCase

  def test_a_float_is_refused
    a = CArray.int32(5).seq
    m = CArray.int32(3, 3).seq
    {
      "sliding_windows: a window size" => -> { a.sliding_windows(1.5) },
      "block_view: a block size"       => -> { CArray.int32(4).seq.block_view(2.5) },
      "tile: a repeat count"           => -> { a.tile(1.5) },
      "roll: a shift"                  => -> { a.roll(1.5) },
      "shift: a shift"                 => -> { a.shift(1.5) },
      "field: offset"                  => -> { CArray.fixlen(2, bytes: 2).field(1.5, :int8) },
      "diagonal: offset"               => -> { m.diagonal(offset: 0.5) },
    }.each do |prefix, call|
      e = assert_raise(TypeError, prefix) { call.() }
      assert_equal "#{prefix} must be an Integer (got Float)", e.message
    end
  end

  def test_an_integer_still_answers
    a = CArray.int32(5).seq
    assert_equal [[0, 1], [1, 2], [2, 3], [3, 4]], a.sliding_windows(2).to_a
    assert_equal [1, 2, 3, 4, 0], a.roll(-1).to_a
    assert_equal [0, 0, 1, 2, 3], a.shift(1).to_a
    assert_equal [1, 5], CArray.int32(3, 3).seq.diagonal(offset: 1).to_a
  end

end

require "test/unit"
require "carray"

# The extremum family on an object array orders cells by <=>, as
# Array#min and #sort do, and raises as Ruby does for a pair <=> cannot
# order.  A Float NaN still loses every contest.

class TestObjectExtremumOrder < Test::Unit::TestCase

  class OnlyCmp
    attr_reader :v
    def initialize (v) @v = v end
    def <=> (o) v <=> o.v end
  end

  class OnlyLt
    attr_reader :v
    def initialize (v) @v = v end
    def < (o) v < o.v end
    def > (o) v > o.v end
  end

  def test_an_element_with_only_spaceship_has_extrema
    vals = [3, 1, 2].map { |x| OnlyCmp.new(x) }
    a = CA_OBJECT(vals)
    assert_equal 1, a.min.v
    assert_equal 3, a.max.v
    assert_equal [1, 3], a.minmax.map(&:v)
    assert_equal 1, a.min_index
    assert_equal 0, a.max_index
    assert_equal [3, 3, 3], a.cummax.to_a.map(&:v)
    assert_equal [3, 1, 1], a.cummin.to_a.map(&:v)
    assert_equal a.sort.to_a.first.v, a.min.v
  end

  def test_unorderable_pairs_raise_as_ruby_does
    b = CA_OBJECT([3, 1].map { |x| OnlyLt.new(x) })
    assert_raise(ArgumentError) { b.min }
    assert_raise(ArgumentError) { CA_OBJECT([1, nil, 2]).min }
    assert_raise(ArgumentError) { CA_OBJECT([1, nil, 2]).cummax }
  end

  def test_nan_and_mixed_numbers
    assert_equal 0.5, CA_OBJECT([1.0, Float::NAN, 0.5]).min
    assert_equal 2.5, CA_OBJECT([1, 2.5, Rational(1, 3)]).max
    x = CA_FLOAT64([1.0, 2.0])
    x.elem_min(0, Float::NAN)
    assert_equal [1.0, 2.0], x.to_a
  end

end

# search_nearest on an object array asks the query for #distance, and says
# so when the query has none.
#
# The object lane of the kernel computes the nearest cell as the minimum of
# query.distance(cell) -- the protocol the 2.0 flat kernel used, back when
# Numeric#distance was a monkey patch.  In 3.0 that definition moved into
# the opt-in refinement in lib/carray/core_extensions.rb, and a refinement
# does not reach a C-level rb_funcall, so nothing an ordinary program holds
# answers #distance any more: the lane raised a bare
# "NoMethodError: undefined method 'distance'" for an Integer as readily as
# for a String.
#
# It now refuses in the library's own vocabulary and names both ways out.
# An object that really defines #distance still measures, so the lane is
# reachable -- it just has to be reached on purpose.

require 'test/unit'
require 'carray'

class TestSearchNearestNeedsAMetric < Test::Unit::TestCase

  # An object that carries a real metric (a plain method, not a refinement).
  class Metric
    include Comparable
    attr_reader :v
    def initialize (v) ; @v = v ; end
    def distance (other) ; (v - other.v).abs ; end
    def <=> (other) ; v <=> other.v ; end
  end

  def test_a_string_query_is_refused_with_a_reason
    e = assert_raise(CArray::DataTypeError) do
      CArray.string(%w[apple fig kiwi]).search_nearest("fig")
    end
    assert_match(/#distance/, e.message)
    assert_match(/String/,    e.message)
    assert_match(/bsearch/,   e.message)
  end

  def test_a_number_stored_as_an_object_is_refused_too
    e = assert_raise(CArray::DataTypeError) do
      CA_OBJECT([1, 5, 9]).search_nearest(4)
    end
    assert_match(/Integer/, e.message)
  end

  def test_the_addr_form_refuses_as_well
    assert_raise(CArray::DataTypeError) do
      CA_OBJECT([[1, 2], [3, 4]]).search_nearest_addr(2, axis: 1)
    end
    assert_raise(CArray::DataTypeError) do
      CArray.string(%w[a b c]).search_nearest_addr("b")
    end
  end

  def test_an_object_that_defines_distance_still_measures
    a = CA_OBJECT([Metric.new(1), Metric.new(5), Metric.new(9)])
    assert_equal 1, a.search_nearest(Metric.new(4))
    assert_equal 0, a.search_nearest(Metric.new(2))
    assert_equal 2, a.search_nearest(Metric.new(100))
  end

  def test_numeric_data_types_are_untouched
    assert_equal 1, CA_FLOAT64([1.0, 5.0, 9.0]).search_nearest(4.0)
    assert_equal 2, CA_INT32([1, 5, 9]).search_nearest(8)
    assert_equal [0, 0], CA_INT32([[1, 9], [1, 9]]).search_nearest(2, axis: 1).to_a
    assert_equal [1, 1], CA_INT32([[1, 9], [1, 9]]).search_nearest(8, axis: 1).to_a
  end

end

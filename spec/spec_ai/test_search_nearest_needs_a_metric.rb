# search_nearest on an object array measures with #distance when the query
# answers it, with arithmetic when the query is a number, and refuses by
# name otherwise.
#
# The lane computed the nearest cell as the minimum of query.distance(cell)
# -- the protocol the 2.0 flat kernel used, back when Numeric#distance was
# a monkey patch.  In 3.0 that definition moved into the opt-in refinement
# in lib/carray/core_extensions.rb, and a refinement does not reach a
# C-level rb_funcall, so nothing an ordinary program holds answered it: the
# lane raised a bare "NoMethodError: undefined method 'distance'" for an
# Integer as readily as for a String.
#
# A number is now measured the way #distance itself would (|a - b|), which
# keeps Rational and BigDecimal exact -- no Float promotion anywhere.  A
# real #distance still wins, so an object that defines one chooses its own
# metric.  What has neither is told so in the library's vocabulary.

require 'test/unit'
require 'carray'
require 'bigdecimal'

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

  def test_the_addr_form_refuses_as_well
    assert_raise(CArray::DataTypeError) do
      CArray.string(%w[a b c]).search_nearest_addr("b")
    end
  end

  def test_a_number_stored_as_an_object_is_measured
    a = CA_OBJECT([1, 5, 9])
    assert_equal 1, a.search_nearest(4)
    assert_equal 0, a.search_nearest(2)
    assert_equal 2, a.search_nearest(100)
  end

  def test_object_numbers_answer_what_the_numeric_data_type_answers
    want = CA_FLOAT64([1.0, 5.0, 9.0])
    got  = CA_OBJECT([1.0, 5.0, 9.0])
    [0.0, 2.9, 4.4, 7.0, 99.0].each do |q|
      assert_equal want.search_nearest(q), got.search_nearest(q), "query #{q}"
    end
  end

  # Measuring by arithmetic rather than through Float keeps the exactness
  # that is the reason to store numbers as objects at all.
  def test_exact_object_numerics_stay_exact
    a = CA_OBJECT([Rational(1, 3), Rational(2, 3)])
    assert_equal 1, a.search_nearest(Rational(3, 5))
    b = CA_OBJECT([BigDecimal("1"), BigDecimal("5")])
    assert_equal 1, b.search_nearest(BigDecimal("4"))
  end

  def test_the_object_axis_and_addr_forms
    a = CA_OBJECT([[1, 9], [1, 9]])
    assert_equal [0, 0], a.search_nearest(2, axis: 1).to_a
    assert_equal [1, 3], a.search_nearest_addr(8, axis: 1).to_a
  end

  def test_masked_cells_are_not_candidates
    a = CA_OBJECT([1, 5, 9])
    a[1] = UNDEF
    assert_equal 0, a.search_nearest(4)
  end

  # A real #distance wins over the arithmetic, so an object can choose its
  # own metric -- here, one that is not |a - b|.
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

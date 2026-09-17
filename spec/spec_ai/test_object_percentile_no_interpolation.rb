# Interpolating between two elements of an object column requires that the
# elements have the arithmetic interpolation means.  Strings do not, and
# they used to go through anyway.
#
# pct_compute_object computes :linear as lo * (1 - r) + hi * r.  String
# has both of those operators, and String#* truncates the Float weight to
# an Integer -- so "b" * 0.7 is "" and percentile(30) on a string column
# quietly answered "" rather than failing.  :midpoint and even-length
# median divide instead, and raised a bare NoMethodError from inside the
# funcall.
#
# Now the two interpolating methods refuse, naming the three picking ones
# that work.  What lands exactly on an element still answers: the refusal
# is at the point interpolation would happen, not at the door.
#
# A column of numbers stored as objects (Integer, Rational, BigDecimal) is
# untouched -- that is the case the object lane exists for.

require 'test/unit'
require 'carray'
require 'bigdecimal'

class TestObjectPercentileNoInterpolation < Test::Unit::TestCase

  def setup
    @odd  = CArray.string(%w[a b c d e])
    @even = CArray.string(%w[a b c d])
  end

  # ---------------- refused ----------------

  def test_linear_refuses_and_says_what_works
    e = assert_raise(CArray::DataTypeError) { @odd.percentile(30) }
    assert_match(/:linear/,  e.message)
    assert_match(/String/,   e.message)
    assert_match(/:lower/,   e.message)
  end

  def test_midpoint_refuses
    assert_raise(CArray::DataTypeError) { @odd.percentile(30, method: :midpoint) }
  end

  def test_even_length_median_refuses
    e = assert_raise(CArray::DataTypeError) { @even.median }
    assert_match(/percentile\(50, method: :lower\)/, e.message)
  end

  def test_per_axis_refuses_the_same_way
    s6 = CArray.string(%w[a b c d e f]).reshape(2, 3)
    s4 = CArray.string(%w[a b c d]).reshape(2, 2)
    assert_raise(CArray::DataTypeError) { s6.percentile(30, axis: 1) }
    assert_raise(CArray::DataTypeError) { s4.median(axis: 1) }
  end

  # ---------------- still answered ----------------

  def test_the_picking_methods_answer
    assert_equal "b", @odd.percentile(30, method: :lower)
    assert_equal "c", @odd.percentile(30, method: :higher)
    assert_equal "b", @odd.percentile(30, method: :nearest)
    assert_equal "b", @even.percentile(50, method: :lower)
  end

  def test_a_percentile_that_lands_on_an_element_answers
    assert_equal "a", @odd.percentile(0)
    assert_equal "c", @odd.percentile(50)
    assert_equal "e", @odd.percentile(100)
  end

  def test_odd_length_median_answers
    assert_equal "c", @odd.median
    assert_equal ["b", "e"],
                 CArray.string(%w[a b c d e f]).reshape(2, 3).median(axis: 1).to_a
  end

  def test_the_picking_methods_answer_per_axis
    s6 = CArray.string(%w[a b c d e f]).reshape(2, 3)
    assert_equal ["a", "d"], s6.percentile(30, axis: 1, method: :lower).to_a
  end

  # ---------------- numbers stored as objects are untouched ----------------

  def test_object_numbers_still_interpolate
    assert_equal 2.5, CA_OBJECT([1, 2, 3, 4]).median
    assert_equal 1.9, CA_OBJECT([1, 2, 3, 4]).percentile(30)
    assert_equal 1.5, CA_OBJECT([1, 2, 3, 4]).percentile(30, method: :midpoint)
    assert_equal [1.5, 3.5], CA_OBJECT([[1, 2], [3, 4]]).median(axis: 1).to_a
  end

  def test_exact_object_numerics_still_interpolate
    assert_equal 0.5, CA_OBJECT([Rational(1, 3), Rational(2, 3)]).median
    assert_equal BigDecimal("1.5"),
                 CA_OBJECT([BigDecimal("1"), BigDecimal("2")]).median
  end

  def test_numeric_data_types_are_untouched
    assert_equal 2.5, CA_INT32([4, 1, 2, 3]).median
    assert_equal 2.2, CA_FLOAT64([1.0, 2.0, 3.0, 4.0, 5.0]).percentile(30)
  end

  # A fixlen surface refuses at the door, as it always has: it has no object
  # lane to reach at all.
  def test_fixlen_still_refuses_at_the_door
    assert_raise(CArray::DataTypeError) { CArray.const_string(%w[a b c]).median }
  end

end

# CArray.arange is part of the NumPy / Numo soft-compatibility layer in
# lib/carray/data_type_extension.rb: the count of elements comes from the
# arguments (start, stop, step) as written, the values come from seq, and the
# data type comes either from the receiving typed class or from a guess over
# the arguments.  The stop bound is exclusive in every form.

require "test/unit"
require "carray"

class TestArange < Test::Unit::TestCase

  def test_one_argument_counts_from_zero
    a = CArray.arange(5)
    assert_equal [0, 1, 2, 3, 4], a.to_a
    assert_equal "int64", a.data_type_name
  end

  def test_two_arguments_are_start_and_exclusive_stop
    assert_equal [2, 3, 4, 5], CArray.arange(2, 6).to_a
  end

  def test_three_arguments_step
    assert_equal [0, 2, 4], CArray.arange(0, 5, 2).to_a
    assert_equal [0, 2, 4], CArray.arange(0, 6, 2).to_a
  end

  def test_negative_step_counts_down
    assert_equal [5, 4, 3, 2, 1], CArray.arange(5, 0, -1).to_a
    assert_equal [5, 3, 1], CArray.arange(5, 0, -2).to_a
  end

  def test_empty_when_stop_is_not_reachable
    assert_equal [], CArray.arange(0, 0).to_a
    assert_equal [], CArray.arange(5, 0).to_a
    assert_equal [], CArray.arange(0, 5, -1).to_a
  end

  def test_float_arguments_land_in_float64
    a = CArray.arange(0.0, 1.0, 0.25)
    assert_equal "float64", a.data_type_name
    assert_equal [0.0, 0.25, 0.5, 0.75], a.to_a
  end

  def test_float_step_element_count_is_not_inflated_by_rounding
    #  (1.0 - 0.0) / 0.1 is just under 10 in IEEE 754; the count must stay 10
    #  rather than gaining an eleventh element from a naive ceil.
    assert_equal 10, CArray.arange(0.0, 1.0, 0.1).elements
  end

  def test_integer_step_dividing_the_span_evenly_counts_exactly
    assert_equal 5, CArray.arange(0, 10, 2).elements
    assert_equal [0, 2, 4, 6, 8], CArray.arange(0, 10, 2).to_a
  end

  def test_typed_class_fixes_the_data_type
    a = CArray::Int32.arange(5)
    assert_equal "int32", a.data_type_name
    assert_equal [0, 1, 2, 3, 4], a.to_a

    b = CArray::Float64.arange(5)
    assert_equal "float64", b.data_type_name
    assert_equal [0.0, 1.0, 2.0, 3.0, 4.0], b.to_a
  end

  def test_typed_class_counts_from_the_arguments_not_the_data_type
    #  The four elements are decided by the float step; the int32 storage
    #  truncates them on store.
    a = CArray::Int32.arange(0, 1, 0.25)
    assert_equal 4, a.elements
    assert_equal [0, 0, 0, 0], a.to_a
  end

  def test_zero_step_is_rejected
    assert_raise(ArgumentError) { CArray.arange(0, 5, 0) }
  end

  def test_wrong_argument_count_is_rejected
    assert_raise(ArgumentError) { CArray.arange }
    assert_raise(ArgumentError) { CArray.arange(0, 1, 2, 3) }
  end

end

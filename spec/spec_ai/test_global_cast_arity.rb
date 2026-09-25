# The global CA_<TYPE>() cast shorthands are defined with arity -1 because the
# Range form takes a step as its second argument.  Nothing else reads a second
# argument and nothing reads a third, so every other multi-argument spelling is
# refused rather than silently ignored -- CA_INT32(0, 2) reads like the shape
# spelling CArray.int32(3, 3) and used to answer with the scalar 0.

require "test/unit"
require "carray"

class TestGlobalCastArity < Test::Unit::TestCase

  CASTS = [:CA_BOOLEAN, :CA_INT8, :CA_UINT8, :CA_INT16, :CA_UINT16,
           :CA_INT32, :CA_UINT32, :CA_INT64, :CA_UINT64,
           :CA_FLOAT32, :CA_FLOAT64, :CA_CMPLX64, :CA_CMPLX128,
           :CA_OBJECT, :CA_SIZE,
           :CA_BYTE, :CA_SHORT, :CA_INT, :CA_FLOAT, :CA_DOUBLE,
           :CA_COMPLEX, :CA_DCOMPLEX]

  # --- refused -------------------------------------------------------------

  def test_a_step_after_an_integer_is_refused
    assert_raise(ArgumentError) { CA_INT32(0, 2) }
  end

  def test_a_step_after_an_array_is_refused
    assert_raise(ArgumentError) { CA_INT32([0, 1], 2) }
    assert_raise(ArgumentError) { CA_INT32([0, 1], [2, 3]) }
  end

  def test_a_step_after_a_string_is_refused
    assert_raise(ArgumentError) { CA_INT32("1 2 3", 5) }
  end

  def test_a_step_after_a_carray_is_refused
    assert_raise(ArgumentError) { CA_INT32(CA_INT8([1, 2]), 5) }
  end

  def test_a_step_after_nil_is_refused
    assert_raise(ArgumentError) { CA_INT32(nil, 2) }
  end

  def test_a_step_after_a_float_is_refused
    assert_raise(ArgumentError) { CA_FLOAT64(1.5, 2) }
  end

  def test_the_message_names_the_class_of_the_first_argument
    CA_INT32(0, 2)
  rescue ArgumentError => e
    assert_match(/step/, e.message)
    assert_match(/Integer/, e.message)
  end

  def test_a_third_argument_is_refused_even_after_a_range
    assert_raise(ArgumentError) { CA_INT32(0..6, 2, 9) }
  end

  def test_more_than_two_arguments_is_refused
    assert_raise(ArgumentError) { CA_INT32(0, 2, 3, 4, 5) }
  end

  def test_every_cast_in_the_family_shares_the_gate
    CASTS.each do |name|
      assert_raise(ArgumentError, "#{name}(0, 2) should be refused") do
        send(name, 0, 2)
      end
      assert_raise(ArgumentError, "#{name}(0..3, 1, 9) should be refused") do
        send(name, 0..3, 1, 9)
      end
    end
  end

  # --- still accepted ------------------------------------------------------

  def test_no_argument_still_gives_an_empty_array
    # Same answer as CA_INT32(nil); kept as it was.
    a = CA_INT32()
    assert_equal [], a.to_a
    assert_equal 0, a.elements
  end

  def test_one_argument_forms_are_untouched
    assert_equal [],           CA_INT32(nil).to_a
    assert_equal [0],          CA_INT32(0).to_a
    assert_equal [0, 1, 2],    CA_INT32([0, 1, 2]).to_a
    assert_equal (0..6).to_a,  CA_INT32(0..6).to_a
    assert_equal [0, 2, 4, 6], CA_INT32((0..6).step(2)).to_a
    assert_equal [1, 2, 3],    CA_INT32("1 2 3").to_a
  end

  def test_a_scalar_argument_still_gives_a_cscalar
    assert_equal CScalar, CA_INT32(0).class
  end

  def test_a_step_after_a_range_is_the_one_two_argument_form
    assert_equal [0, 2, 4, 6], CA_INT32(0..6, 2).to_a
    assert_equal [0, 2],       CA_SIZE(0..3, 2).to_a
    assert_equal [0.0, 2.5, 5.0], CA_FLOAT64(0..5, 2.5).to_a
  end

  def test_a_descending_range_with_a_step_counts_down
    # The path Range#to_ca takes for a descending range (carray/basics.rb).
    assert_equal [3, 2, 1, 0], CA_OBJECT(3..0, 1).to_a
    assert_equal [3, 1],       CA_OBJECT(3..0, 2).to_a
  end

  def test_an_exclusive_range_with_a_step_is_accepted
    assert_equal [0, 2, 4], CA_INT32(0...6, 2).to_a
  end

  def test_a_zero_step_is_still_a_runtime_error
    assert_raise(RuntimeError) { CA_INT32(0..6, 0) }
  end

  # --- the fixlen sibling, which has always checked its own arity ----------

  def test_fixlen_keeps_its_own_arity_and_bytes_option
    assert_equal ["ab"],  CA_FIXLEN(["ab"]).to_a
    assert_equal ["ab"],  CA_FIXLEN(["ab"], bytes: 2).to_a
    assert_raise(ArgumentError) { CA_FIXLEN("a", "b", "c") }
  end

end

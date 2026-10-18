$LOAD_PATH.unshift File.expand_path('../../ext', __dir__)
$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'carray'
require 'bigdecimal'
require 'test/unit'

# An integer array given a non-Integer offset or step (a Float, a Rational,
# a BigDecimal) takes the real progression offset + step*i cut toward zero,
# as a store takes a float; the run is checked to fit before it is written.

class TestSeqRealProgression < Test::Unit::TestCase

  def test_each_cell_is_the_real_value_cut
    assert_equal [0, 1, 1, 2], CArray.int32(4).seq(0.5, 0.5).to_a
    assert_equal [0, 0, 1], CArray.int32(3).seq(-0.5, 1.0).to_a
    assert_equal [0, 1, 3], CArray.int32(3).seq(0, 1.5).to_a
    assert_equal [[0, 0, 1, 1]] * 2, CArray.int32(2, 4).seq(0, 0.5, axis: 1).to_a
  end

  def test_rational_and_bigdecimal_steps
    assert_equal [0, 0, 1, 1], CArray.int32(4).seq(0, 1/2r).to_a
    assert_equal [0, 0, 1], CArray.int32(3).seq(0, BigDecimal("0.5")).to_a
    assert_equal [0.0, 0.5, 1.0], CArray.float64(3).seq(0, 1/2r).to_a
  end

  def test_a_run_that_does_not_fit_raises_before_writing
    a = CArray.int8(100).seq
    before = a.to_a
    assert_raise(RangeError) { a.seq!(0, 1.5) }
    assert_raise(RangeError) { CArray.int32(2).seq(0, 1e20) }
    assert_raise(RangeError) { CArray.uint8(3).seq(0, -0.5) }
    assert_equal before, a.to_a
    assert_equal [1, 0, 0], CArray.uint8(3).seq(1, -0.5).to_a
  end

  def test_nan_raises_as_a_store_does
    assert_raise(FloatDomainError) { CArray.int32(2).seq(0, Float::NAN) }
    assert_raise(FloatDomainError) { CArray.int32(2).seq(Float::NAN) }
  end

  def test_integer_runs_keep_wrapping
    assert_equal [126, 127, -128], CArray.int8(3).seq(126, 1).to_a
  end

end

class TestSeqRefusesBeforeTouching < Test::Unit::TestCase

  # An argument that is not a number is refused before the fill opens, so
  # the array and its mask are as they were.
  def test_mask_is_kept_on_refusal
    [[:x], [0, "y"], [Complex(1, 1)]].each do |args|
      m = CA_INT32([1, UNDEF, 3])
      assert_raise(TypeError) { m.seq!(*args) }
      assert_equal [1, UNDEF, 3], m.to_a, args.inspect
    end
  end

  def test_object_fill_that_raises_keeps_the_mask
    m = CA_OBJECT([1, UNDEF, 3])
    assert_raise(NoMethodError) { m.seq!(1, :bogus_method) }
    assert_equal [false, true, false], m.is_masked.to_a
  end

  def test_a_fill_clears_the_mask
    m = CA_INT32([1, UNDEF, 3])
    m.seq!
    assert_equal [0, 1, 2], m.to_a
  end

end

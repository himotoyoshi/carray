require "test/unit"
require "carray"

# A lazy monop chain runs in one buffer, casts included, so a cast inside a
# chain has to keep the rules a cast has on its own.
class TestLazyMonopChainCast < Test::Unit::TestCase

  def masked_nan
    a = CA_DOUBLE([1.5, Float::NAN, 3.5])
    a[1] = UNDEF
    a
  end

  def test_cast_at_the_leaf_skips_a_masked_nan
    assert_equal [-1, UNDEF, -3], (-(masked_nan.as_type(:int32).lazy)).to_a
  end

  def test_cast_inside_the_chain_skips_a_masked_nan
    assert_equal [1, UNDEF, 3], (-((-masked_nan.lazy).as_type(:int32).lazy)).to_a
  end

  def test_cast_of_a_masked_object_cell_is_skipped
    o = CA_OBJECT([1, nil, 3])
    o[1] = UNDEF
    assert_equal [-1.0, UNDEF, -3.0], (-(o.as_type(:float64).lazy)).to_a
  end

  def test_cast_to_boolean_skips_a_masked_cell
    x = CA_INT32([1, 2, 0])
    x[1] = UNDEF
    assert_equal [false, UNDEF, true], x.as_type(:boolean).lazy.not.to_a
  end

  def test_a_chain_still_refuses_an_unmasked_cell
    a = CA_DOUBLE([Float::NAN, 1.0, 2.0])
    a[2] = UNDEF
    assert_raise(FloatDomainError) { (-(a.as_type(:int32).lazy)).copy }
  end

  def test_the_answer_for_a_cell_does_not_depend_on_a_mask_elsewhere
    o = CA_OBJECT([1, "x", 3])
    assert_raise(ArgumentError) { (-(o.as_type(:float64).lazy)).copy }
    o2 = CA_OBJECT([1, "x", 3, 4])
    o2[3] = UNDEF
    assert_raise(ArgumentError) { (-(o2.as_type(:float64).lazy)).copy }
  end

  def test_a_masked_chain_that_raises_leaves_later_expressions_working
    o = CA_OBJECT([1, "x", 3, nil])
    o[3] = UNDEF
    100.times { assert_raise(ArgumentError) { (-(o.as_type(:float64).lazy)).copy } }
    assert_equal [2.0], (CA_DOUBLE([1.0]).lazy + 1).to_a
  end

  # An object chain is recorded so that a cell holding an expression over it
  # is caught; a cast over the chain evaluates the chain, which is no cycle.
  def test_cast_over_an_object_chain_is_not_a_cycle
    o = CA_OBJECT([-1, 2])
    assert_equal [1.0, 2.0], o.lazy.abs.as_type(:float64).to_a
    assert_equal [1.0, -2.0], (-(o.lazy)).as_type(:float64).to_a
    assert_equal [1.0, 2.0], (-(-(o.lazy.abs))).as_type(:float32).to_a
  end

  def test_a_marker_inside_an_object_chain_is_not_a_cycle
    o = CA_OBJECT([1, 2])
    assert_equal [1, 2], o.lazy.abs.lazy.lazy.abs.to_a
  end

  # A cast takes the cells of an object chain to numbers in a buffer that
  # held VALUEs, and the collector must not read the numbers as VALUEs.
  def test_a_chain_from_objects_to_numbers_survives_gc
    o = CA_OBJECT([-2, 0.5, 1, 2.5] * 4)
    begin
      GC.stress = true
      a = o.as_type(:cmplx128).as_type(:int32).lazy.frac.to_a
      b = o.lazy.abs.as_type(:cmplx128).as_type(:int32).lazy.ceil.to_a
    ensure
      GC.stress = false
    end
    assert_equal [0] * 16, a
    assert_equal [2, 0, 1, 2] * 4, b
  end

  def test_a_cast_over_a_ternary_is_lazy_as_over_a_binary
    x = CA_DOUBLE([0.5, 1.5, 2.5])
    assert_instance_of CABinOp, (x.lazy + 1).as_type(:float32) + 1
    assert_instance_of CABinOp, x.lazy.clip(1, 2).as_type(:float32) + 1
    assert_equal [2.0, 2.5, 3.0], (x.lazy.clip(1, 2).as_type(:float32) + 1).to_a
  end
end

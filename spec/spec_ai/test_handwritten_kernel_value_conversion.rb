$LOAD_PATH.unshift File.expand_path('../../ext', __dir__)
$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'carray'
require 'test/unit'
require 'bigdecimal'

# Hand-written doors that put one value into a cell, or read an index, must
# convert it the way the indexer does: `self[i] = v` and `self[idx]`.

module IndexerAgreement

  TYPES = [:int8, :uint8, :int16, :uint16, :int32, :uint32, :int64, :uint64,
           :float32, :float64, :boolean]

  VALUES = [0, 1, 2, -1, 127, 128, 255, 256, 300, -129, 2**31, 2**40,
            2**63 - 1, 2**63, 2**64, -2**63, 1.5, -0.5, 1e20, Float::NAN,
            Float::INFINITY, 1/2r, 7/1r, BigDecimal("3"), true, false]

  # The value the cell holds afterwards, or the class of the exception.
  def outcome
    yield.to_a
  rescue StandardError => e
    e.class
  end

  def each_case
    TYPES.each do |t|
      VALUES.each do |v|
        yield t, v
      end
    end
  end

  def fresh(t)
    CArray.new(t, [2])
  end

end

class TestScatterReplaceAgreesWithStore < Test::Unit::TestCase
  include IndexerAgreement

  def test_scalar_converts_as_store_does
    each_case do |t, v|
      store   = outcome { a = fresh(t); a[0] = v; a }
      scatter = outcome { a = fresh(t); a.scatter_replace!([0], v); a }
      assert_equal store.to_s, scatter.to_s, "#{t} <- #{v.inspect}"
    end
  end

end

class TestElemStoreAgreesWithStore < Test::Unit::TestCase
  include IndexerAgreement

  def test_entity_scalar_converts_as_store_does
    each_case do |t, v|
      store = outcome { a = fresh(t); a[0] = v; a }
      elem  = outcome { a = fresh(t); a.elem_store(0, v); a }
      assert_equal store.to_s, elem.to_s, "#{t} <- #{v.inspect}"
    end
  end

end

class TestElemExtremumAgreesOnEntityAndView < Test::Unit::TestCase
  include IndexerAgreement

  # The entity fast path must answer what the view path answers.
  def test_entity_matches_view
    (TYPES - [:boolean]).each do |t|
      VALUES.each do |v|
        next if v == true || v == false
        [:elem_max, :elem_min].each do |m|
          ent  = outcome { a = CArray.new(t, [2]) { 5 }; a.send(m, 0, v); a }
          view = outcome {
            root = CArray.new(t, [3]) { 5 }
            root[1..2].send(m, 0, v)
            root[1..2]
          }
          assert_equal view.to_s, ent.to_s, "#{m} #{t} <- #{v.inspect}"
        end
      end
    end
  end

end

class TestScatterScalars < Test::Unit::TestCase

  def test_value_out_of_range_raises
    assert_raise(RangeError) { CA_INT8([0, 0]).scatter_add!([0], 300) }
    assert_raise(RangeError) { CA_UINT8([3]).scatter_max!([0], -1) }
    assert_raise(RangeError) { CA_INT32([5, 5]).scatter_add!([0], 1e20) }
  end

  def test_nan_into_integer_raises
    assert_raise(FloatDomainError) { CA_INT32([5, 5]).scatter_add!([0], Float::NAN) }
  end

  def test_bignum_scalar_broadcasts
    a = CA_INT64([0, 0])
    a.scatter_add!([0, 1], 2**63 - 1)
    assert_equal [2**63 - 1, 2**63 - 1], a.to_a
  end

  def test_rational_scalar_broadcasts
    a = CA_FLOAT64([0, 0])
    a.scatter_add!([0, 1], 1/2r)
    assert_equal [0.5, 0.5], a.to_a
  end

  def test_undef_replace_masks_the_targets
    a = CA_INT32([1, 2, 3])
    a.scatter_replace!([0, 2], UNDEF)
    assert_equal [UNDEF, 2, UNDEF], a.to_a
  end

  def test_undef_into_the_arithmetic_family_changes_nothing
    a = CA_INT32([1, 2, 3])
    a.scatter_add!([0, 2], UNDEF)
    assert_equal [1, 2, 3], a.to_a
  end

  def test_boolean_scalar_two_is_refused
    b = CArray.boolean(2)
    assert_raise(CArray::DataTypeError) { b.scatter_replace!([0], 2) }
  end

  def test_masked_coordinate_path_of_put_nd_converts_too
    x = CArray.int8(2).seq
    q = CA_INT64([[0], [1]])
    q[1, 0] = UNDEF
    assert_raise(RangeError) { x.put_nd(q, 300) }
  end

end

class TestIndexArraysAreIntegers < Test::Unit::TestCase

  def test_float_index_array_is_refused
    a = CA_INT32([10, 20, 30])
    assert_raise(IndexError) { a.scatter_add!(CA_FLOAT64([1.5]), 1) }
    assert_raise(IndexError) { a.project(CA_FLOAT64([1.7, -0.5])) }
    assert_raise(IndexError) {
      CArray.int32(2, 3).seq.take_along_axis(CA_FLOAT64([[0, 1, 2], [0, 1, 2]]), axis: 1)
    }
  end

  def test_huge_uint64_index_is_out_of_range
    a = CA_INT32([0, 0, 0])
    assert_raise(IndexError) { a.scatter_add!(CA_UINT64([2**64 - 1]), 1) }
    assert_raise(IndexError) { a.take_along_axis(CA_UINT64([2**64 - 1]), axis: 0) }
    assert_equal [0, 0, 0], a.to_a
  end

  def test_float_element_index_is_refused
    a = CA_INT32([10, 20, 30])
    assert_raise(IndexError) { a.elem_fetch(1.5) }
    assert_raise(IndexError) { a.elem_fetch([1.5]) }
    assert_raise(IndexError) { a.elem_store(1.5, 0) }
  end

  def test_axis_beyond_int_is_out_of_range
    a = CArray.int32(2, 3).seq
    assert_raise(ArgumentError) {
      a.take_along_axis(CArray.int64(2, 3) { 0 }, axis: 2**32 + 1)
    }
  end

end

class TestCountNonFloatQueries < Test::Unit::TestCase

  def test_fractional_rational_matches_no_integer
    assert_equal 0, CA_INT32([0, 1, 1, 2, 3]).count(1/2r)
    assert_equal 0, CA_INT32([0, 1, 1, 2, 3]).count(BigDecimal("0.5"))
  end

  def test_integral_rational_matches_its_integer
    assert_equal 2, CA_INT32([0, 1, 1, 2, 3]).count(1/1r)
    assert_equal 1, CA_INT64([2**62, 1]).count(Rational(2**62, 1))
    assert_equal 1, CA_INT32([0, 3]).count(BigDecimal("3"))
  end

end

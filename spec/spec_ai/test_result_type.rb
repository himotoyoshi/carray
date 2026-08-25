# frozen_string_literal: true
#
# spec_ai/test_result_type.rb
#
# Tests for CArray.result_type — N-ary common-type resolver that walks
# ca_cast_table (carray_core.c) by left fold. Accepts CArray instances,
# Integer type codes, Symbols/Strings, and data classes.
#
# Returns an Integer data_type code consistent with CArray.sizeof /
# CArray.data_type? / CArray.new etc.

require "test/unit"
require_relative "../../lib/carray"

class TestResultType < Test::Unit::TestCase

  # ---------- arity ----------

  def test_zero_args_raises
    assert_raise(ArgumentError) { CArray.result_type }
  end

  def test_single_arg_returns_that_type
    assert_equal CA_INT32,   CArray.result_type(:int32)
    assert_equal CA_FLOAT64, CArray.result_type(:float64)
    assert_equal CA_OBJECT,  CArray.result_type(:object)
  end

  # ---------- pairwise promotions (CArray table policy) ----------

  def test_int_to_float_promotion
    assert_equal CA_FLOAT32, CArray.result_type(:int32, :float32)
    assert_equal CA_FLOAT64, CArray.result_type(:int64, :float64)
  end

  def test_signed_unsigned_follows_table
    # CArray table chooses uint32 for (int8, uint32) — lossy but the
    # established policy of ca_cast_table. Pin the behavior.
    assert_equal CA_UINT32, CArray.result_type(:int8, :uint32)
  end

  def test_float_to_complex_promotion
    # f64 vs c64: table promotes f64 -> c64 (lossy in precision but
    # the established policy).
    assert_equal CA_CMPLX64, CArray.result_type(:float64, :cmplx64)
    assert_equal CA_CMPLX128, CArray.result_type(:float32, :cmplx128)
  end

  def test_identity_pair
    assert_equal CA_INT32, CArray.result_type(:int32, :int32)
  end

  def test_boolean_promotes_to_anything_numeric
    assert_equal CA_INT8,    CArray.result_type(:boolean, :int8)
    assert_equal CA_FLOAT64, CArray.result_type(:boolean, :float64)
  end

  # ---------- N-ary fold ----------

  def test_nary_walk
    # bool < int8 < uint16 < float32, then float32 vs int64 -> float32
    # (table policy: i64 -> f32 lossy)
    t = CArray.result_type(:boolean, :int8, :uint16, :float32, :int64)
    assert_equal CA_FLOAT32, t
  end

  def test_order_independent_when_total
    # Within the totally-ordered numeric chain, order should not matter.
    chain = [:boolean, :int8, :uint16, :float32]
    chain.permutation(4) do |perm|
      assert_equal CA_FLOAT32, CArray.result_type(*perm),
        "permutation #{perm.inspect} should yield float32"
    end
  end

  # ---------- argument types ----------

  def test_accepts_carray_instances
    a = CArray.int32(3).seq
    b = CArray.float32(3).seq
    assert_equal CA_FLOAT32, CArray.result_type(a, b)
  end

  def test_accepts_mixed_carray_symbol_integer
    a = CArray.int32(3).seq
    b = CArray.float32(3).seq
    assert_equal CA_FLOAT64, CArray.result_type(a, b, :float64)
    assert_equal CA_FLOAT64, CArray.result_type(a, b, CA_FLOAT64)
  end

  def test_accepts_string
    assert_equal CA_FLOAT64, CArray.result_type("int32", "float64")
  end

  # ---------- compatibility / errors ----------

  def test_object_absorbs_fixlen
    # Per ca_cast_table: fixlen -> object is allowed (test==1 at [fix][obj]).
    # So result_type(:object, :fixlen) succeeds and yields :object,
    # not a raise. Pin the behavior.
    assert_equal CA_OBJECT, CArray.result_type(:object, :fixlen)
    assert_equal CA_OBJECT, CArray.result_type(:fixlen, :object)
  end

  def test_unknown_data_type_string_raises
    assert_raise(RuntimeError) { CArray.result_type(:no_such_type) }
  end

  # ---------- consistency with operator coercion ----------

  def test_matches_binary_operator_data_type
    # result_type(a, b) for two CArrays should agree with the data_type that
    # a + b would actually produce (operator path goes through
    # rb_ca_cast_self_or_other which uses ca_cast_table similarly).
    pairs = [
      [CArray.int8(2).seq,    CArray.int32(2).seq],
      [CArray.int32(2).seq,   CArray.float32(2).seq],
      [CArray.float32(2).seq, CArray.float64(2).seq],
      [CArray.uint16(2).seq,  CArray.int64(2).seq + 1],
    ]
    pairs.each do |a, b|
      sum = a + b
      assert_equal sum.data_type, CArray.result_type(a, b),
        "result_type(#{a.data_type}, #{b.data_type}) should match (a+b).data_type"
    end
  end

  # ---------- return form ----------

  def test_returns_symbol_usable_downstream
    # PROPOSAL_DTYPE_SYMBOL_FLIP rev3: result_type returns Symbol so
    # the API family matches CArray.value_to_data_type and ca.data_type.
    t = CArray.result_type(:int32, :float32)
    assert_kind_of Symbol, t
    # The returned Symbol must round-trip through data_type_name and be
    # accepted by CArray.new.
    assert_equal "float32", CArray.data_type_name(t)
    arr = CArray.new(t, [3])
    assert_equal t, arr.data_type
  end

end

# frozen_string_literal: true
#
# spec_ai/test_data_type_idiom_transparency.rb
#
# S.3.A — idiom transparency tests for PROPOSAL_DTYPE_SYMBOL_FLIP.
#
# These tests pin that existing user-code idioms involving CA_* data_type
# constants and ca.data_type continue to work *identically* before and
# after the Symbol flip.  They must pass on BOTH sides of the flip:
#
#   - Pre-flip:  CA_INT64 = 8 (Integer), ca.data_type → 8 (Integer)
#   - Post-flip: CA_INT64 = :int64 (Symbol), ca.data_type → :int64 (Symbol)
#
# Both `case when CA_INT64` and `data_type == CA_INT64` work uniformly
# because both sides flip together.  This file is the load-bearing
# regression detector for the flip — if S.1 implementation accidentally
# desynchronizes the constant and the accessor, these tests fail and
# pin the breakage at the exact idiom.
#
# Audit basis (proposal §S.0 rev3): 4 idiom families × 7+15+20+7 sites.
# Each family is exercised here against representative data_types.

require "test/unit"
require_relative "../../lib/carray"

class TestDtypeIdiomTransparency < Test::Unit::TestCase

  # All numeric data_types that user code actually exercises (= S.0 audit).
  # CA_FIXLEN excluded from numeric idiom matrix (= needs bytes:),
  # exercised separately.  CA_OBJECT excluded from arithmetic idioms.
  NUMERIC_DTYPES = [
    CA_BOOLEAN,
    CA_INT8,  CA_UINT8,  CA_INT16, CA_UINT16,
    CA_INT32, CA_UINT32, CA_INT64, CA_UINT64,
    CA_FLOAT32, CA_FLOAT64,
    CA_CMPLX64, CA_CMPLX128,
  ].freeze

  # --------------------------------------------------------------
  # (1) `case when CA_*` idiom — math.rb / table.rb / imagemagick.rb
  # --------------------------------------------------------------

  def test_case_when_idiom_dispatches_correctly
    # Build one array per data_type; the `case when` over its data_type
    # should land in the corresponding branch.  This is the most common
    # user-facing dispatch pattern in lib/carray.
    NUMERIC_DTYPES.each do |dt|
      ca = CArray.new(dt, [3])
      branch = case ca.data_type
               when CA_BOOLEAN  then :bool
               when CA_INT8     then :i8
               when CA_UINT8    then :u8
               when CA_INT16    then :i16
               when CA_UINT16   then :u16
               when CA_INT32    then :i32
               when CA_UINT32   then :u32
               when CA_INT64    then :i64
               when CA_UINT64   then :u64
               when CA_FLOAT32  then :f32
               when CA_FLOAT64  then :f64
               when CA_CMPLX64  then :c64
               when CA_CMPLX128 then :c128
               else                  :other
               end
      expected = {
        CA_BOOLEAN => :bool,
        CA_INT8 => :i8, CA_UINT8 => :u8, CA_INT16 => :i16, CA_UINT16 => :u16,
        CA_INT32 => :i32, CA_UINT32 => :u32, CA_INT64 => :i64, CA_UINT64 => :u64,
        CA_FLOAT32 => :f32, CA_FLOAT64 => :f64,
        CA_CMPLX64 => :c64, CA_CMPLX128 => :c128,
      }[dt]
      assert_equal expected, branch,
        "case-when dispatch failed for data_type constant #{dt.inspect}"
    end
  end

  def test_case_when_multi_constant_branch
    # math.rb / imagemagick.rb idiom: multiple constants in one `when`.
    [CA_INT8, CA_UINT8].each do |dt|
      ca = CArray.new(dt, [3])
      branch = case ca.data_type
               when CA_UINT8, CA_INT8   then :int8_family
               when CA_UINT16, CA_INT16 then :int16_family
               else                          :other
               end
      assert_equal :int8_family, branch
    end
  end

  # --------------------------------------------------------------
  # (2) `data_type == CA_*` equality idiom — lazy.rb / math.rb /
  # ordering.rb / serialize.rb / struct.rb / testing.rb 等
  # --------------------------------------------------------------

  def test_equality_idiom_all_numeric
    NUMERIC_DTYPES.each do |dt|
      ca = CArray.new(dt, [3])
      assert_operator ca.data_type, :==, dt,
        "ca.data_type == #{dt.inspect} failed"
      assert_equal false, (ca.data_type != dt),
        "ca.data_type != #{dt.inspect} unexpectedly true"
    end
  end

  def test_equality_idiom_object_fixlen
    co = CArray.object(3)
    assert_operator co.data_type, :==, CA_OBJECT

    cf = CArray.new(CA_FIXLEN, [3], bytes: 4)
    assert_operator cf.data_type, :==, CA_FIXLEN
  end

  def test_inequality_filters_correctly
    # imagemagick.rb pattern: `if data_type != CA_FIXLEN and data_type != CA_OBJECT`
    ca = CArray.float64(3)
    assert_equal true, (ca.data_type != CA_FIXLEN && ca.data_type != CA_OBJECT)
    co = CArray.object(3)
    assert_equal false, (co.data_type != CA_FIXLEN && co.data_type != CA_OBJECT)
  end

  # --------------------------------------------------------------
  # (3) Constructor / data_type-arg idiom — CArray.new, to_type, fixlen
  # --------------------------------------------------------------

  def test_constructor_with_data_type_constant
    NUMERIC_DTYPES.each do |dt|
      ca = CArray.new(dt, [3])
      assert_operator ca.data_type, :==, dt,
        "CArray.new(#{dt.inspect}, [3]).data_type round-trip failed"
    end
  end

  def test_to_type_preserves_target_data_type
    src = CA_INT32([1, 2, 3])
    NUMERIC_DTYPES.each do |dt|
      next if dt == CA_BOOLEAN  # to_type semantics differ for boolean target
      out = src.to_type(dt)
      assert_operator out.data_type, :==, dt,
        "src.to_type(#{dt.inspect}).data_type mismatch"
    end
  end

  def test_constructor_with_alias_constant
    # CA_DOUBLE = CA_FLOAT64, CA_INT = CA_INT32 等の alias 透過
    a = CArray.new(CA_DOUBLE, [3])
    assert_operator a.data_type, :==, CA_FLOAT64
    assert_operator a.data_type, :==, CA_DOUBLE  # alias identity

    b = CArray.new(CA_INT, [3])
    assert_operator b.data_type, :==, CA_INT32
    assert_operator b.data_type, :==, CA_INT
  end

  # --------------------------------------------------------------
  # (4) Hash key / Array element idiom
  # --------------------------------------------------------------

  def test_hash_key_lookup_with_data_type_constant
    # User code idiom: mapping data_type → custom value
    table = {
      CA_INT32   => :thirty_two,
      CA_INT64   => :sixty_four,
      CA_FLOAT64 => :double,
    }
    [CA_INT32, CA_INT64, CA_FLOAT64].each do |dt|
      ca = CArray.new(dt, [3])
      assert_equal table[dt], table[ca.data_type],
        "Hash[ca.data_type] lookup failed for #{dt.inspect}"
    end
  end

  def test_array_include_data_type_constant
    int_family = [CA_INT8, CA_INT16, CA_INT32, CA_INT64]
    NUMERIC_DTYPES.each do |dt|
      ca = CArray.new(dt, [3])
      assert_equal int_family.include?(dt),
                   int_family.include?(ca.data_type),
        "Array#include? mismatch for #{dt.inspect}"
    end
  end

  # --------------------------------------------------------------
  # (5) result_type return value participates in same idioms
  # --------------------------------------------------------------

  def test_result_type_value_usable_in_case_when
    promoted = CArray.result_type(CA_INT32, CA_FLOAT32)
    branch = case promoted
             when CA_FLOAT32, CA_FLOAT64 then :float
             when CA_INT32, CA_INT64     then :int
             else                             :other
             end
    assert_equal :float, branch  # int32 + float32 → float64 per ca_cast_table
  end

  def test_result_type_value_usable_in_equality
    promoted = CArray.result_type(CA_INT8, CA_INT64)
    assert_operator promoted, :==, CA_INT64
  end

  def test_result_type_value_usable_as_constructor_arg
    promoted = CArray.result_type(CA_INT16, CA_INT32)
    ca = CArray.new(promoted, [3])
    assert_operator ca.data_type, :==, CA_INT32
  end

  # --------------------------------------------------------------
  # (6) Comparison with literal value (post-flip natural form
  # = Symbol literal; pre-flip = Integer literal)
  # --------------------------------------------------------------
  #
  # These compare against the constant indirectly (= the constant IS
  # the literal in both eras).  Direct literal comparison is tested in
  # S.3.B (Symbol-only acceptance).

  def test_constant_self_identity
    # CA_INT64 == CA_INT64 trivially, but covers the constant being
    # well-defined value (not coincidentally truthy).
    assert_equal CA_INT64, CA_INT64
    assert_not_equal CA_INT64, CA_INT32
    assert_not_equal CA_INT64, CA_FLOAT64
  end

  def test_alias_constants_equal_canonical
    # User can write CA_DOUBLE or CA_FLOAT64 interchangeably.
    assert_equal CA_FLOAT64, CA_DOUBLE
    assert_equal CA_INT32, CA_INT
    # And short forms vs long forms:
    assert_equal CA_UINT8, CA_BYTE
    assert_equal CA_INT16, CA_SHORT
    assert_equal CA_FLOAT32, CA_FLOAT
  end

  # --------------------------------------------------------------
  # (7) CArray.data_type_name accepts the data_type value uniformly
  # --------------------------------------------------------------

  def test_data_type_name_round_trip
    NUMERIC_DTYPES.each do |dt|
      ca = CArray.new(dt, [3])
      name = CArray.data_type_name(ca.data_type)
      assert_kind_of String, name
      assert_false name.empty?
      # The name should canonically describe the data_type.
      expected = {
        CA_BOOLEAN => "boolean",
        CA_INT8 => "int8", CA_UINT8 => "uint8",
        CA_INT16 => "int16", CA_UINT16 => "uint16",
        CA_INT32 => "int32", CA_UINT32 => "uint32",
        CA_INT64 => "int64", CA_UINT64 => "uint64",
        CA_FLOAT32 => "float32", CA_FLOAT64 => "float64",
        CA_CMPLX64 => "cmplx64", CA_CMPLX128 => "cmplx128",
      }[dt]
      assert_equal expected, name,
        "data_type_name(#{dt.inspect}) returned #{name.inspect}, expected #{expected.inspect}"
    end
  end

end

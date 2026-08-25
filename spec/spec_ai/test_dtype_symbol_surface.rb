# frozen_string_literal: true
#
# spec_ai/test_data_type_symbol_surface.rb
#
# S.3.B — Symbol surface acceptance tests for PROPOSAL_DTYPE_SYMBOL_FLIP.
#
# Pins the core contract of the Symbol flip (post-flip only):
#   - ca.data_type returns Symbol (e.g. :int64)
#   - CA_* constants are Symbol-valued
#   - alias constants share canonical Symbol identity (Q4 = β)
#   - CArray.result_type returns Symbol
#   - Symbol#to_s yields the legacy data_type_name string
#   - Symbol literal idioms (== :int64, pattern matching) work
#
# These tests are formal acceptance pins for AC1-AC5 of the proposal.

require "test/unit"
require_relative "../../lib/carray"

class TestDtypeSymbolSurface < Test::Unit::TestCase

  ALL_NUMERIC_DTYPES = [
    [CA_BOOLEAN,  :boolean],
    [CA_INT8,     :int8],
    [CA_UINT8,    :uint8],
    [CA_INT16,    :int16],
    [CA_UINT16,   :uint16],
    [CA_INT32,    :int32],
    [CA_UINT32,   :uint32],
    [CA_INT64,    :int64],
    [CA_UINT64,   :uint64],
    [CA_FLOAT32,  :float32],
    [CA_FLOAT64,  :float64],
    [CA_CMPLX64,  :cmplx64],
    [CA_CMPLX128, :cmplx128],
  ].freeze

  # --------------------------------------------------------------
  # (1) ca.data_type returns Symbol (AC1)
  # --------------------------------------------------------------

  def test_data_type_returns_symbol_for_all_numeric
    ALL_NUMERIC_DTYPES.each do |const, sym|
      ca = CArray.new(const, [3])
      assert_kind_of Symbol, ca.data_type,
        "ca.data_type for #{sym.inspect} should be Symbol"
      assert_equal sym, ca.data_type,
        "ca.data_type for #{sym.inspect} mismatch"
    end
  end

  def test_data_type_returns_symbol_for_object
    co = CArray.object(3)
    assert_kind_of Symbol, co.data_type
    assert_equal :object, co.data_type
  end

  def test_data_type_returns_symbol_for_fixlen
    cf = CArray.new(CA_FIXLEN, [3], bytes: 8)
    assert_kind_of Symbol, cf.data_type
    assert_equal :fixlen, cf.data_type
  end

  # --------------------------------------------------------------
  # (2) CA_* constants are Symbol (AC2)
  # --------------------------------------------------------------

  def test_ca_constants_are_symbols
    ALL_NUMERIC_DTYPES.each do |const, sym|
      assert_kind_of Symbol, const,
        "Constant for #{sym.inspect} should be Symbol"
      assert_equal sym, const,
        "Constant for #{sym.inspect} mismatch"
    end
    assert_kind_of Symbol, CA_OBJECT
    assert_kind_of Symbol, CA_FIXLEN
    assert_equal :object, CA_OBJECT
    assert_equal :fixlen, CA_FIXLEN
  end

  # --------------------------------------------------------------
  # (3) alias constants share canonical Symbol (AC3, Q4 = β)
  # --------------------------------------------------------------

  def test_alias_constants_equal_canonical
    assert_equal CA_FLOAT64, CA_DOUBLE
    assert_equal :float64, CA_DOUBLE

    assert_equal CA_FLOAT32, CA_FLOAT
    assert_equal :float32, CA_FLOAT

    assert_equal CA_INT32, CA_INT
    assert_equal :int32, CA_INT

    assert_equal CA_UINT8, CA_BYTE
    assert_equal :uint8, CA_BYTE

    assert_equal CA_INT16, CA_SHORT
    assert_equal :int16, CA_SHORT
  end

  def test_alias_constants_share_object_identity
    # canonical Symbol path: same Symbol object (interned)
    assert_same CA_FLOAT64, CA_DOUBLE
    assert_same CA_FLOAT32, CA_FLOAT
    assert_same CA_INT32,   CA_INT
    assert_same CA_UINT8,   CA_BYTE
    assert_same CA_INT16,   CA_SHORT
  end

  # --------------------------------------------------------------
  # (4) CArray.result_type returns Symbol (AC4)
  # --------------------------------------------------------------

  def test_result_type_returns_symbol
    r = CArray.result_type(CA_INT8, CA_FLOAT32)
    assert_kind_of Symbol, r
  end

  def test_result_type_promotion_correctness
    # CArray promotion (per ca_cast_table): int + float keeps float width.
    assert_equal CA_INT64,   CArray.result_type(CA_INT8, CA_INT64)
    assert_equal CA_FLOAT32, CArray.result_type(CA_INT32, CA_FLOAT32)
    assert_equal CA_FLOAT64, CArray.result_type(CA_FLOAT32, CA_FLOAT64)
  end

  def test_result_type_accepts_symbols
    r = CArray.result_type(:int8, :float32)
    assert_kind_of Symbol, r
    assert_equal CArray.result_type(CA_INT8, CA_FLOAT32), r
  end

  # --------------------------------------------------------------
  # (5) Symbol#to_s round-trip with data_type_name (AC5)
  # --------------------------------------------------------------

  def test_symbol_to_s_matches_data_type_name
    ALL_NUMERIC_DTYPES.each do |const, sym|
      ca = CArray.new(const, [3])
      assert_equal CArray.data_type_name(ca.data_type), ca.data_type.to_s,
        "ca.data_type.to_s mismatch with data_type_name for #{sym.inspect}"
    end
  end

  # --------------------------------------------------------------
  # (6) Symbol literal idioms (== :int64, etc.)
  # --------------------------------------------------------------

  def test_symbol_literal_equality
    ca = CArray.int64(3)
    assert_equal true, (ca.data_type == :int64)
    assert_equal false, (ca.data_type == :int32)
  end

  def test_symbol_literal_in_case_when
    ca = CArray.float64(3)
    branch = case ca.data_type
             when :int64, :int32 then :int
             when :float64, :float32 then :float
             else :other
             end
    assert_equal :float, branch
  end

  # --------------------------------------------------------------
  # (7) Pattern matching (Ruby 3.0+)
  # --------------------------------------------------------------

  def test_pattern_matching_with_symbol_data_type
    ca = CArray.int64(3)
    result = case ca.data_type
             in :int64
               :matched_int64
             in :float64
               :matched_float64
             else
               :no_match
             end
    assert_equal :matched_int64, result
  end

  # --------------------------------------------------------------
  # (8) data_type_code reverse mapping (Symbol → Integer)
  # --------------------------------------------------------------

  def test_data_type_code_round_trip
    ALL_NUMERIC_DTYPES.each do |const, _sym|
      code = CArray.data_type_code(const)
      assert_kind_of Integer, code
      ca = CArray.new(code, [3])
      assert_equal const, ca.data_type
    end
  end

  # --------------------------------------------------------------
  # (9) data_type_name accepts Symbol, Integer, Class, String
  # --------------------------------------------------------------

  def test_data_type_name_accepts_symbol
    assert_equal "int64", CArray.data_type_name(:int64)
    assert_equal "float64", CArray.data_type_name(CA_FLOAT64)
  end

  def test_data_type_name_accepts_integer
    code = CArray.data_type_code(CA_INT64)
    assert_equal "int64", CArray.data_type_name(code)
  end

  def test_data_type_name_accepts_string
    assert_equal "int64", CArray.data_type_name("int64")
  end

end

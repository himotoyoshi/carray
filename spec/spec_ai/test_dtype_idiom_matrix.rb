# frozen_string_literal: true
#
# spec_ai/test_data_type_idiom_matrix.rb
#
# S.3.C — Comprehensive matrix coverage for PROPOSAL_DTYPE_SYMBOL_FLIP.
#
# Cross-product of {numeric data_types} × {view family} × {idiom} as a
# boring-but-thorough release-quality safeguard.  Each test method
# walks the matrix and asserts the idiom holds for every cell.
#
# Idioms:  case-when, ==, Hash key, constructor arg
# Views:   entity, CABlock, CARefer (reshape), CATranspose

require "test/unit"
require_relative "../../lib/carray"

class TestDtypeIdiomMatrix < Test::Unit::TestCase

  NUMERIC_DTYPES = [
    CA_BOOLEAN,
    CA_INT8,  CA_UINT8,  CA_INT16, CA_UINT16,
    CA_INT32, CA_UINT32, CA_INT64, CA_UINT64,
    CA_FLOAT32, CA_FLOAT64,
    CA_CMPLX64, CA_CMPLX128,
  ].freeze

  # Each entity has shape [4, 3] so we can derive CABlock / CARefer /
  # CATranspose views cleanly across all data_types.
  def make_views(dt)
    ent = CArray.new(dt, [4, 3])
    {
      entity:    ent,
      block:     ent[1..3, nil],
      refer:     ent.reshape(3, 4),
      transpose: ent.transpose,
    }
  end

  VIEW_KINDS = [:entity, :block, :refer, :transpose].freeze

  # --------------------------------------------------------------
  # (A) Every view preserves data_type as the same Symbol across views
  # --------------------------------------------------------------

  def test_data_type_consistent_across_views
    NUMERIC_DTYPES.each do |dt|
      views = make_views(dt)
      VIEW_KINDS.each do |kind|
        v = views[kind]
        assert_equal dt, v.data_type,
          "#{kind} view of #{dt.inspect} lost data_type identity"
      end
    end
  end

  # --------------------------------------------------------------
  # (B) case-when dispatch idiom transparent across views
  # --------------------------------------------------------------

  def test_case_when_idiom_across_views
    NUMERIC_DTYPES.each do |dt|
      views = make_views(dt)
      VIEW_KINDS.each do |kind|
        v = views[kind]
        branch = case v.data_type
                 when CA_BOOLEAN                              then :bool
                 when CA_INT8, CA_INT16, CA_INT32, CA_INT64   then :int_s
                 when CA_UINT8, CA_UINT16, CA_UINT32, CA_UINT64 then :int_u
                 when CA_FLOAT32, CA_FLOAT64                  then :float
                 when CA_CMPLX64, CA_CMPLX128                 then :cmplx
                 else                                              :other
                 end
        expected =
          case dt
          when CA_BOOLEAN                              then :bool
          when CA_INT8, CA_INT16, CA_INT32, CA_INT64   then :int_s
          when CA_UINT8, CA_UINT16, CA_UINT32, CA_UINT64 then :int_u
          when CA_FLOAT32, CA_FLOAT64                  then :float
          when CA_CMPLX64, CA_CMPLX128                 then :cmplx
          end
        assert_equal expected, branch,
          "case-when mismatch for #{kind} view of #{dt.inspect}"
      end
    end
  end

  # --------------------------------------------------------------
  # (C) Equality idiom transparent across views
  # --------------------------------------------------------------

  def test_equality_idiom_across_views
    NUMERIC_DTYPES.each do |dt|
      views = make_views(dt)
      VIEW_KINDS.each do |kind|
        v = views[kind]
        assert_operator v.data_type, :==, dt,
          "== idiom failed for #{kind} view of #{dt.inspect}"
      end
    end
  end

  # --------------------------------------------------------------
  # (D) Hash key idiom transparent across views
  # --------------------------------------------------------------

  def test_hash_key_idiom_across_views
    table = NUMERIC_DTYPES.each_with_index.to_h { |dt, i| [dt, i] }
    NUMERIC_DTYPES.each do |dt|
      views = make_views(dt)
      VIEW_KINDS.each do |kind|
        v = views[kind]
        assert_equal table[dt], table[v.data_type],
          "Hash key idiom failed for #{kind} view of #{dt.inspect}"
      end
    end
  end

  # --------------------------------------------------------------
  # (E) Constructor arg idiom — using v.data_type to build a fresh array
  # --------------------------------------------------------------

  def test_constructor_arg_idiom_across_views
    NUMERIC_DTYPES.each do |dt|
      views = make_views(dt)
      VIEW_KINDS.each do |kind|
        v = views[kind]
        fresh = CArray.new(v.data_type, [2])
        assert_equal dt, fresh.data_type,
          "Constructor from #{kind} view of #{dt.inspect} produced wrong data_type"
      end
    end
  end

end

# frozen_string_literal: true
#
# spec_ai/test_caremap_skeleton.rb
#
# M.1 skeleton tests for CARemap (PROPOSAL_CAREMAP_INTERNAL.md).
#
# CARemap is reachable from Ruby as the class of `ca[mapper]` when
# mapper is a same-shape CA_SIZE CArray and ref is N-D (N ≥ 2; the
# 1-D + 1-D fast path routes to CAGrid via rb_ca_scan_index upstream).
# Construction goes through rb_ca_remap_new -> ca_remap_setup which
# enforces shape + data_type constraints; we exercise that from
# ordinary Ruby.

require "test/unit"
require_relative "../../lib/carray"

class TestCARemapSkeleton < Test::Unit::TestCase

  def make_idx (shape, values = nil)
    a = CArray.new(CA_SIZE, shape)
    if values
      a[] = values
    else
      a.seq
    end
    a
  end

  # ---------------------------------------------------------------- construction

  def test_construct_same_shape_2d
    ref = CArray.float64(3, 4)
    idx = make_idx([3, 4])
    view = ref[idx]
    assert_kind_of CARemap, view
    assert_equal [3, 4], view.shape
    assert view.parent.equal?(ref)
    assert view.mapper.equal?(idx)
  end

  def test_construct_same_shape_3d
    ref = CArray.int32(2, 3, 4)
    idx = make_idx([2, 3, 4])
    view = ref[idx]
    assert_kind_of CARemap, view
    assert_equal [2, 3, 4], view.shape
    assert_equal CA_INT32, view.data_type
  end

  # ---------------------------------------------------------------- constraints / routing

  def test_1d_routes_to_cagrid_not_caremap
    # 1-D ref + 1-D mapper is handled upstream by rb_ca_scan_index
    # and resolves to CAGrid (not CARemap).
    ref = CArray.float64(5).seq
    idx = make_idx([5])
    refute_kind_of CARemap, ref[idx]
  end

  def test_ndim_mismatch_routes_away_from_caremap
    ref = CArray.float64(3, 4)
    idx = make_idx([12])
    refute_kind_of CARemap, ref[idx]
  end

  def test_per_axis_dim_mismatch_routes_away_from_caremap
    ref = CArray.float64(3, 4)
    idx = make_idx([3, 5])
    refute_kind_of CARemap, ref[idx]
  end

  def test_idx_not_ca_size_routes_away_from_caremap
    ref = CArray.float64(3, 4)
    idx = CArray.int32(3, 4).seq
    refute_kind_of CARemap, ref[idx]
  end

  # ---------------------------------------------------------------- class visibility

  def test_caremap_class_is_exposed
    assert Object.const_defined?(:CARemap),
           "CARemap must be defined as a Ruby class"
    assert Object.const_defined?(:CARemapMask),
           "CARemapMask must be defined as a Ruby class"
    assert_equal CAView, CARemap.superclass
    assert_equal CARemap, CARemapMask.superclass
  end

  def test_ca_obj_remap_constant_not_exposed
    assert !Object.const_defined?(:CA_OBJ_REMAP),
           "CA_OBJ_REMAP must not be exposed as a Ruby constant"
  end

  def test_caremap_cannot_be_instantiated_from_ruby
    assert_raise(TypeError) { CARemap.new }
    assert_raise(TypeError) { CARemap.allocate }
  end

  def test_caremap_has_no_public_constructor_method
    refute CArray.respond_to?(:remap),
           "CArray.remap must not exist (CARemap has no public ctor)"
  end

  # ---------------------------------------------------------------- mapper accessor

  def test_mapper_returns_same_object
    ref = CArray.float64(2, 3).seq
    idx = make_idx([2, 3], [5, 3, 1, 0, 4, 2])
    view = ref[idx]
    assert view.mapper.equal?(idx), "view.mapper must return the same CArray"
    assert_equal [[5, 3, 1], [0, 4, 2]], view.mapper.to_a
  end

  def test_mapper_kept_alive_across_gc
    # The mapper is reachable only via view.mapper after the local
    # binding drops -- the rb_ivar_set retention must hold across GC.
    ref = CArray.float64(2, 2).seq
    view = nil
    Proc.new {
      idx = make_idx([2, 2], [3, 2, 1, 0])
      view = ref[idx]
    }.call
    GC.start
    GC.start
    assert_equal [[3, 2], [1, 0]], view.mapper.to_a
    assert_equal [[3.0, 2.0], [1.0, 0.0]], view.to_a
  end
end

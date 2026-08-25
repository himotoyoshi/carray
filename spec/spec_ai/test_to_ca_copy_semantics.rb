# frozen_string_literal: true
#
# to_ca / copy / dup semantics (3.0 split).
#
# 3.0 splits the formerly-aliased `to_ca` and `copy`:
#
#   - to_ca : "give me a CArray, doing the least work". A CArray (entity OR
#             data view) is already a CArray, so to_ca returns self (no copy).
#             A lazy view (CABinOp/...) has no data yet, so it forces
#             evaluation into an entity (Ruby `to_a`/force convention).
#   - copy  : always allocates a new independent entity, even from an entity;
#             materialises a view into an entity.
#   - dup   : standard Ruby shallow copy (same-class); for an entity this is
#             an independent buffer, for a view a new view onto the same parent.
#
# Pins:
#   - to_ca on an entity returns the same object (no copy)
#   - to_ca on CScalar / CAWrap also returns self (entity? == true)
#   - to_ca on a data view returns self (stays a view, no copy)
#   - to_ca on a lazy view forces evaluation into an entity
#   - copy always returns a distinct, independent entity (materialises views)
#   - writing through a copy never touches the source

require "test/unit"
require "carray"

class TestToCaCopySemantics < Test::Unit::TestCase

  def test_to_ca_on_entity_returns_self
    a = CArray.int32(3).seq
    assert_equal true, a.entity?
    assert_same a, a.to_ca
  end

  def test_to_ca_on_scalar_returns_self
    s = CScalar.int32 { 5 }
    assert_equal true, s.entity?
    assert_same s, s.to_ca
  end

  def test_to_ca_on_data_view_returns_self
    a = CArray.int32(2, 3).seq
    v = a[0, nil]                 # CABlock data view
    assert_equal false, v.entity?
    assert_same v, v.to_ca         # already a CArray → returned as-is, no copy
  end

  def test_to_ca_on_view_materialise_is_copy
    a = CArray.int32(2, 3).seq
    v = a[0, nil]
    r = v.copy                     # copy is the materialise-to-entity path
    assert_equal true, r.entity?
    assert_not_same v, r
    r[0] = 99
    assert_equal 0, a[0, 0]        # independent of the source
  end

  def test_to_ca_on_lazy_view_forces_evaluation
    a = CArray.int32(3).seq
    ex = a.lazy + 1                # CABinOp lazy view (no data yet)
    r = ex.to_ca
    assert_equal true, r.entity?   # forced into a concrete entity
    assert_equal [1, 2, 3], r.to_a
  end

  def test_copy_always_makes_independent_entity
    a = CArray.int32(3).seq
    c = a.copy
    assert_not_same a, c
    assert_equal true, c.entity?
    c[0] = 99
    assert_equal 0, a[0]          # source untouched
  end

  def test_dup_on_entity_is_independent
    a = CArray.int32(3).seq
    d = a.dup
    assert_not_same a, d
    d[0] = 99
    assert_equal 0, a[0]
  end

  # dup/clone are Ruby's shallow copy: on a VIEW they return another view onto
  # the same storage, NOT an independent copy. This is a known trap — `copy` is
  # the reliable independent-copy method. Pinned so the behaviour is explicit.
  def test_dup_on_view_shares_storage_trap
    a = CArray.int32(2, 3).seq
    v = a[0, nil]                 # CABlock view
    d = v.dup
    assert_equal false, d.entity?  # still a view, not materialised
    d[1] = 99
    assert_equal 99, a[0, 1]       # writing the dup reached the source
  end

  def test_to_ca_and_copy_agree_on_contents
    a = CArray.float64(2, 3).seq
    a[0, 1] = UNDEF               # carry a mask too
    assert_equal a.to_a, a.copy.to_a
    assert_equal a.is_masked.to_a, a.copy.is_masked.to_a
  end

  # --- container to_ca ------------------------------------------------------
  #
  # Array#to_ca and Range#to_ca are the two container coercions; both land as
  # CA_OBJECT (an explicit CA_INT32(...) is how a numeric type is asked for).
  # Range enumerates the Ruby way -- a Float range is not iterable and an
  # endless one cannot become an array, so both raise instead of quietly
  # producing a degenerate axis -- with one departure: a descending integer
  # range counts down rather than coming back empty, agreeing with the cast
  # form CA_INT32(3..0) and with the index form ca[3..0].

  def test_array_to_ca_is_object
    a = [1, 2, 3].to_ca
    assert_equal :object, a.data_type
    assert_equal [1, 2, 3], a.to_a
  end

  def test_range_to_ca_is_object
    a = (0..3).to_ca
    assert_equal :object, a.data_type
    assert_equal 1, a.ndim
    assert_equal [0, 1, 2, 3], a.to_a
  end

  def test_range_to_ca_excludes_end
    assert_equal [0, 1, 2], (0...3).to_ca.to_a
  end

  def test_range_to_ca_counts_down_when_descending
    assert_equal [3, 2, 1, 0], (3..0).to_ca.to_a
    assert_equal [3, 2, 1], (3...0).to_ca.to_a
    # agrees with the cast form and with the index form
    assert_equal CA_INT32(3..0).to_a, (3..0).to_ca.to_a
    assert_equal CA_INT32(3...0).to_a, (3...0).to_ca.to_a
  end

  def test_range_to_ca_empty_and_single
    assert_equal [], (0...0).to_ca.to_a
    assert_equal [0], (0..0).to_ca.to_a
  end

  def test_range_to_ca_non_integer_members
    assert_equal ["a", "b", "c"], ("a".."c").to_ca.to_a
  end

  def test_range_to_ca_rejects_float_range
    # (0.0..3.0) is not iterable; use CArray.linspace / span! for a float axis
    assert_raise(TypeError) { (0.0..3.0).to_ca }
  end

  def test_range_to_ca_rejects_unbounded_range
    assert_raise(RangeError) { (0..).to_ca }
    assert_raise(TypeError) { (..3).to_ca }
  end

  def test_range_reaches_the_coercion_entry_points
    assert_equal [0, 1, 2, 3], CArray.wrap_readonly(0..3).to_a
    assert_equal [3, 2, 1, 0], CArray.wrap_readonly(3..0).to_a
    assert_equal [0, 1, 2, 3], CArray.cast(0..3).to_a
  end

  # --- ArithmeticSequence to_ca ---------------------------------------------
  #
  # (0..10).step(2) is an Enumerator::ArithmeticSequence, not a Range, so it
  # needs its own coercion; it is how a strided or float axis gets written.
  # An endless one is rejected up front because enumerating it never returns
  # (an endless Range at least raises).

  def test_arithmetic_sequence_to_ca
    a = (0..10).step(2).to_ca
    assert_equal :object, a.data_type
    assert_equal [0, 2, 4, 6, 8, 10], a.to_a
    assert_equal [0, 2, 4, 6, 8], (0...10).step(2).to_ca.to_a
    assert_equal [0, 3, 6, 9], ((0..10) % 3).to_ca.to_a
  end

  def test_arithmetic_sequence_to_ca_float_step
    assert_equal [0.0, 0.25, 0.5, 0.75, 1.0],
                 (0.0..1.0).step(0.25).to_ca.to_a
  end

  def test_arithmetic_sequence_to_ca_counts_down_when_descending
    assert_equal [10, 8, 6, 4, 2, 0], (10..0).step(2).to_ca.to_a
    assert_equal [10, 8, 6, 4, 2], (10...0).step(2).to_ca.to_a
    # an already-negative step needs no help
    assert_equal [10, 8, 6, 4, 2, 0], 10.step(0, -2).to_ca.to_a
  end

  def test_arithmetic_sequence_to_ca_rejects_endless
    # to_a on these never returns, so the guard has to come first
    assert_raise(RangeError) { (0..).step(2).to_ca }
    assert_raise(RangeError) { 10.step(by: -2).to_ca }
  end

  def test_arithmetic_sequence_reaches_the_coercion_entry_points
    assert_equal [0, 2, 4, 6, 8, 10],
                 CArray.wrap_readonly((0..10).step(2)).to_a
  end
end

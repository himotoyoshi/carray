# ---------------------------------------------------------------------------
# spec_ai/test_lazy_marker_lift_matrix.rb
#
# Deployment coverage for the CALazyMarker lift
# (= devel/PROPOSAL_LAZY_MARKER_LIFT.md sections 4 and 5, Phase 2).
#
# The rule the lift is deployed by is stated as a rule, not as a list:
#
#   a view-creating method whose shape is fixed at construction and which
#   only moves positions keeps the marker on top; everything else does not
#
# so this file is table-driven.  Adding a view method means adding a row to
# LIFTED or to NOT_LIFTED, and both halves are checked -- a method that is
# supposed to be transparent to the lift is asserted to be transparent, not
# merely left out.
#
# Sibling: devel/bench_lazy_view_kind_matrix.rb covers the same ground in
# the performance direction (a missed deployment shows up there as a fuse
# expression that is slower than the eager one).  This file covers the
# structural direction, which is what stays true regardless of machine.
# ---------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path('../../../ext', __FILE__)
$LOAD_PATH.unshift File.expand_path('../../../lib', __FILE__)

require 'test/unit'
require 'carray'

class TestLazyMarkerLiftMatrix < Test::Unit::TestCase

  # Walks the chain under a lifted result: there must be exactly one marker,
  # on top, and the chain must reach storage.  Some index forms build more
  # than one view on the way down (`[[1,3,5]]` is a CABlock over a CARefer,
  # `:_` a CARefer over a CABlock), so the depth is not fixed -- what is
  # fixed is that no second marker appears and the bottom is an entity.
  def assert_single_marker_on_top (got, name)
    assert_equal CALazyMarker, got.class, name
    node = got.parent
    depth = 0
    while node.is_a?(CAView)
      assert_equal false, node.is_a?(CALazyMarker),
                   "#{name}: a second marker at depth #{depth}"
      node = node.parent
      depth += 1
      flunk "#{name}: view chain did not bottom out" if depth > 8
    end
    assert_equal CArray, node.class, "#{name}: chain bottom"
  end

  def entity
    CArray.int32(4, 5) { |j, i| j * 5 + i }
  end

  def masked_entity
    a = entity
    a[1, 2] = UNDEF
    a
  end

  # === the lifted set =====================================================
  #
  # Every one of these is "shape fixed at construction, positions only".
  # `[]` is exercised separately below, once per index form.

  LIFTED = {
    "shift"          => ->(v) { v.shift(1, 0) },
    "shift fill"     => ->(v) { v.shift(1, 0, fill_value: -1) },
    "roll"           => ->(v) { v.roll(2, 1) },
    "flip"           => ->(v) { v.flip(0) },
    "reverse"        => ->(v) { v.reverse },
    "transpose"      => ->(v) { v.transpose },
    "reshape"        => ->(v) { v.reshape(20) },
    "flatten"        => ->(v) { v.flatten },
    "window"         => ->(v) { v.window(-1..2, 0..4) },
    "diagonal"       => ->(v) { v.diagonal },
    "tile"           => ->(v) { v.tile(2, 1) },
    "refer"          => ->(v) { v.refer },
  }.freeze

  # === the index forms of `[]` ============================================
  #
  # All the CA_REG_* branches converge on one lift site, so this table
  # is what says so.  `treat` names what the form is expected to get:
  #   :lift    -> a CArray view, marker on top
  #   :scalar  -> not a CArray at all, handed back untouched
  #   :other   -> not a CArray (an iterator), handed back untouched
  INDEX_FORMS = {
    "ADDRESS       [5]"          => [->(v) { v[5] },              :scalar],
    "ADDRESS_CPLX  [[1,3,5]]"    => [->(v) { v[[1, 3, 5]] },      :lift],
    "FLATTEN       [nil]"        => [->(v) { v[nil] },            :lift],
    "POINT         [1,2]"        => [->(v) { v[1, 2] },           :scalar],
    "ALL           [nil,nil]"    => [->(v) { v[nil, nil] },       :lift],
    "BLOCK         [0..1,nil]"   => [->(v) { v[0..1, nil] },      :lift],
    "SELECT        [boolean]"    => [->(v) { v[v.class == CALazyMarker ? SEL : SEL] }, :lift],
    "MAPPING       [int CArray]" => [->(v) { v[MAP] },            :lift],
    "GRID          [ints, ints]" => [->(v) { v[I0, I1] },         :lift],
    "METHOD_CALL   [:eq, 3]"     => [->(v) { v[:eq, 3] },         :lift],
    "NEWAXIS       [:_,nil,nil]" => [->(v) { v[:_, nil, nil] },   :lift],
    "ITERATOR      [:>,nil]"     => [->(v) { v[:>, nil] },        :other],
  }.freeze

  SEL = CArray.boolean(4, 5) { |j, i| (i + j) % 2 == 0 }
  MAP = CA_INT32([[0, 1], [2, 3]])
  I0  = CA_INT32([0, 2])
  I1  = CA_INT32([1, 3])

  # === the excluded set ===================================================
  #
  # These are user-facing and return CArrays, so leaving them out of the
  # deployment is a decision, not an oversight.  Asserting it keeps the
  # boundary of the rule visible.
  NOT_LIFTED = {
    "copy"           => ->(v) { v.copy },          # owns its data
    "to_ca"          => ->(v) { v.to_ca },         # materialises
    "sort"           => ->(v) { v.sort },          # reorders values
    "sort_copy"      => ->(v) { v.sort_copy },     # reorders values
    "value"          => ->(v) { v.value },         # changes what the mask means
    "strip_mask"     => ->(v) { v.strip_mask(0) }, # changes what the mask means
  }.freeze

  # === lifted: shape ======================================================

  def test_lifted_methods_put_the_marker_on_top
    a = entity
    LIFTED.each do |name, f|
      got = f.call(a.lazy)
      # One wrapper, on top, over a chain that reaches storage without
      # another marker in it.  That is the whole invariant.
      assert_single_marker_on_top(got, name)
      #
      # The view's own class is NOT asserted to match the entity path.
      # `reshape` builds a CAStride when ca_reshape_try_strides accepts its
      # receiver and a CARefer otherwise, and it asks the marker rather than
      # what the marker wraps -- so the entity path yields CAStride where
      # the marker path yields CARefer.  Measured, the two cost the same
      # (0.00114 s against 0.00119 s materialising a 4M reshape), and every
      # contract below holds either way, so this is left as an incidental
      # difference rather than pinned or chased.
    end
  end

  def test_lifted_methods_agree_with_the_entity_path
    a = entity
    LIFTED.each do |name, f|
      assert_equal f.call(a).to_a, f.call(a.lazy).to_a, name
    end
  end

  def test_lifted_methods_agree_under_a_mask
    a = masked_entity
    LIFTED.each do |name, f|
      want = f.call(a)
      got  = f.call(a.lazy)
      assert_equal want.has_mask?, got.has_mask?, name
      assert_equal want.mask.to_a, got.mask.to_a, name if want.has_mask?
      assert_equal want.to_a, got.to_a, name
    end
  end

  # === lifted: behaviour ==================================================

  # The point of the lift: the result takes part in lazy dispatch, so an
  # expression written over it stays fused.
  def test_lifted_results_are_lazy_operands
    a = entity
    LIFTED.each do |name, f|
      assert_equal true, f.call(a.lazy).__lazy_view__?, name
    end
  end

  def test_expressions_over_lifted_results_stay_lazy
    a = entity
    LIFTED.each do |name, f|
      v = f.call(a.lazy)
      assert_equal CABinOp, (v + v).class, name
      assert_equal (f.call(a) + f.call(a)).to_a, (v + v).to_ca.to_a, name
    end
  end

  def test_lifted_results_are_read_only
    a = entity
    LIFTED.each do |name, f|
      assert_equal true, f.call(a.lazy).read_only?, name
    end
  end

  def test_lifted_results_materialise_to_an_entity
    a = entity
    LIFTED.each do |name, f|
      t = f.call(a.lazy).to_ca
      assert_equal CArray, t.class, name
      assert_equal f.call(a).to_a, t.to_a, name
    end
  end

  # === `[]` index forms ===================================================

  def test_index_forms_get_the_treatment_the_table_names
    a = entity
    INDEX_FORMS.each do |name, (f, treat)|
      got = f.call(a.lazy)
      case treat
      when :lift
        assert_single_marker_on_top(got, name)
      when :scalar
        assert_equal false, got.is_a?(CArray), name
        assert_equal f.call(a), got, name
      when :other
        assert_equal false, got.is_a?(CArray), name
        assert_equal f.call(a).class, got.class, name
      end
    end
  end

  def test_index_forms_agree_with_the_entity_path
    a = entity
    INDEX_FORMS.each do |name, (f, treat)|
      next if treat == :other      # an iterator has no value to compare
      want = f.call(a)
      got  = f.call(a.lazy)
      if want.is_a?(CArray)
        assert_equal want.to_a, got.to_a, name
      else
        assert_equal want, got, name
      end
    end
  end

  def test_index_forms_agree_under_a_mask
    a = masked_entity
    INDEX_FORMS.each do |name, (f, treat)|
      next if treat == :other
      want = f.call(a)
      got  = f.call(a.lazy)
      next unless want.is_a?(CArray)
      assert_equal want.has_mask?, got.has_mask?, name
      assert_equal want.to_a, got.to_a, name
    end
  end

  # === the excluded set ===================================================

  def test_excluded_methods_are_not_lifted
    a = entity
    NOT_LIFTED.each do |name, f|
      got = f.call(a.lazy)
      assert_equal false, got.is_a?(CALazyMarker), name
      assert_equal f.call(a).class, got.class, name
    end
  end

  def test_excluded_methods_agree_with_the_entity_path
    [entity, masked_entity].each do |a|
      NOT_LIFTED.each do |name, f|
        assert_equal f.call(a).to_a, f.call(a.lazy).to_a, name
      end
    end
  end

  # `copy` owning its data is the reason it is excluded, so assert the
  # ownership rather than only the class.
  def test_copy_of_a_marker_is_independent
    a = entity
    c = a.lazy.copy
    c[0, 0] = 999
    assert_equal 0, a[0, 0]
  end

  # `value` reads through the mask.  This one is worth its own test: the
  # internal refer builder had to be taught to drop a marker, or the
  # storage underneath stayed masked and the values read back as UNDEF.
  def test_value_of_a_marker_reads_past_the_mask
    a = masked_entity
    assert_equal a.value.to_a, a.lazy.value.to_a
    assert_equal false, a.lazy.value.has_mask?
    assert_equal a[1, 2].nil? ? nil : a.value[1, 2], a.lazy.value[1, 2]
  end
end

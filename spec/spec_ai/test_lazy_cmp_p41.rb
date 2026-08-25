require "test/unit"
require "carray"

# PROPOSAL_LAZY_ELEMENTWISE_VIEW Phase 4 (P.4.1) — CAMonCmp / CABinCmp
# smoke + structural pinning.
#
# Smoke scope (P.4.1):
#   - bincmp :lt operator (`a.lazy < b`) → CABinCmp, byte parity vs
#     eager `a < b`
#   - moncmp :is_nan (`a.lazy.is_nan`) → CAMonCmp, byte parity vs eager
#   - output data_type = CA_BOOLEAN
#   - mask propagation
#   - rev2 §0.5 #1 model: operand-data_type scratches, peak 0–2 (P.4.1
#     always uses 2 for bincmp / 1 for moncmp; leaf-opt deferred)
#   - rev2 §0.5 #4: Phase 2 `&` operator already routes lazy; pin that
#     `(a.lazy < 0)` returns CABinCmp and `(a.lazy < 0) & ...` builds
#     CABinOp(bit_and) over CABinCmp operands

class TestLazyCmpP41 < Test::Unit::TestCase
  N = 100

  def setup
    @a = CArray.float64(N) { |k| (k - N/2) * 0.1 }
    @b = CArray.float64(N) { |k| (k - N/2 + 5) * 0.1 }
  end

  # === bincmp ===

  def test_lt_construct_returns_cabincmp
    view = @a.lazy < @b
    assert_kind_of CABinCmp, view
    assert_equal CA_BOOLEAN, view.data_type
    assert_equal @a.dim, view.dim
  end

  def test_lt_byte_parity_vs_eager
    eager  = @a < @b
    lazy   = (@a.lazy < @b).to_ca
    assert_equal CA_BOOLEAN, lazy.data_type
    assert_equal eager.data_type, lazy.data_type
    assert_equal eager.to_a, lazy.to_a
  end

  def test_lt_scalar_right
    eager = @a < 0.0
    lazy  = (@a.lazy < 0.0).to_ca
    assert_equal eager.to_a, lazy.to_a
  end

  def test_lt_marker_collapse
    # a.lazy marker is collapsed by CABinCmp builder; the resulting
    # view's parent is the entity, not the marker.
    view = @a.lazy < @b
    assert_kind_of CArray, view.parent
    refute_kind_of CALazyMarker, view.parent
  end

  def test_lt_read_only_raises_on_assign
    view = @a.lazy < @b
    assert_raise(RuntimeError) { view[0] = true }
  end

  def test_lt_xfer_stride_uses_arena_or_leaf_inplace
    # P.4.3 model: each operand is either pulled into an arena scratch
    # OR consumed via leaf-inplace (= use parent->ptr + offset when the
    # operand is a contig entity at common data_type).  Sum scratch_count +
    # leaf_inplace_count = 2 per materialise (one bookkeeping event per
    # operand).  For two entity leaves at f64 (the smoke case), both
    # take the leaf-inplace path → scratch_count = 0, leaf = 2.
    CABinCmp.__reset_scratch_counter__
    CABinCmp.__reset_materialise_counter__
    CABinCmp.__reset_leaf_inplace_counter__ if CABinCmp.respond_to?(:__reset_leaf_inplace_counter__)
    _ = (@a.lazy < @b).to_ca
    assert_operator CABinCmp.__materialise_count__, :>=, 1
    total = CABinCmp.__scratch_count__
    total += CABinCmp.__leaf_inplace_count__ if CABinCmp.respond_to?(:__leaf_inplace_count__)
    assert_equal CABinCmp.__materialise_count__ * 2, total,
                 "P.4.3 model: scratch + leaf_inplace must sum to 2 per materialise"
  end

  def test_lt_mask_propagation
    a = @a.dup
    b = @b.dup
    a[0..4]    = UNDEF
    b[95..99]  = UNDEF
    eager = a < b
    lazy  = (a.lazy < b).to_ca
    assert_equal eager.mask.to_a, lazy.mask.to_a
    # Where unmasked, values match
    eager.elements.times do |k|
      next if eager.mask[k]
      assert_equal eager[k], lazy[k], "mismatch at #{k}"
    end
  end

  # === moncmp ===

  def test_is_nan_construct_returns_camoncmp
    view = @a.lazy.is_nan
    assert_kind_of CAMonCmp, view
    assert_equal CA_BOOLEAN, view.data_type
  end

  def test_is_nan_byte_parity_vs_eager
    # Inject NaN into a few positions
    a = @a.dup
    a[10] = Float::NAN
    a[50] = Float::NAN
    eager = a.is_nan
    lazy  = a.lazy.is_nan.to_ca
    assert_equal eager.to_a, lazy.to_a
  end

  def test_is_nan_integer_source_const_false
    # rev2 §0.5 #3: integer is_nan uses per-data_type kernel (no
    # constant-fold); for integer source, every cell is false.
    int_ary = CArray.int32(N) { |k| k }
    eager = int_ary.is_nan
    lazy  = int_ary.lazy.is_nan.to_ca
    assert_equal eager.to_a, lazy.to_a
    assert_equal CA_BOOLEAN, lazy.data_type
    # All cells false
    lazy.elements.times do |k|
      assert_equal false, lazy[k]
    end
  end

  def test_is_nan_integer_mask_propagation
    # rev2 §0.5 #3: masked cells propagate, NOT lost via constant-fold.
    int_ary = CArray.int32(N) { |k| k }
    int_ary[0..9] = UNDEF
    eager = int_ary.is_nan
    lazy  = int_ary.lazy.is_nan.to_ca
    assert_equal eager.mask.to_a, lazy.mask.to_a
  end

  def test_is_nan_read_only_raises_on_assign
    view = @a.lazy.is_nan
    assert_raise(RuntimeError) { view[0] = true }
  end

  # === composition (Phase 2 operator routing audit) ===

  def test_bincmp_and_with_phase2_operator
    # rev2 §0.5 #4: `&` is already in Phase 2 LAZY_BINOP_OP_IDS; verify
    # that `(a.lazy < 0) & (b.lazy < 0)` builds CABinOp(bit_and) over
    # two CABinCmp operands and that the result is bit-parity with
    # eager.
    eager = (@a < 0.0) & (@b < 0.0)
    view  = (@a.lazy < 0.0) & (@b.lazy < 0.0)
    assert_kind_of CABinOp, view
    lazy  = view.to_ca
    assert_equal CA_BOOLEAN, lazy.data_type
    assert_equal eager.to_a, lazy.to_a
  end

  def test_bincmp_over_binop
    # ((a + b).lazy < 0) — CABinCmp parent is CABinOp.  Pins that
    # CABinCmp accepts lazy operands (= chain composability).
    eager = (@a + @b) < 0.0
    view  = (@a.lazy + @b) < 0.0
    assert_kind_of CABinCmp, view
    lazy  = view.to_ca
    assert_equal eager.to_a, lazy.to_a
  end
end

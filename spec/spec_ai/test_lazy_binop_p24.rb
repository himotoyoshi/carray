# PROPOSAL_LAZY_ELEMENTWISE_VIEW Phase 2 (P.2.4) — general broadcast.
#
# Scope (= prep doc rev3 P.2.4, Q8 (a) verdict):
#   - same-shape (regression)
#   - same-ndim size-1 broadcast on either side (via ca_broadcast_pair)
#   - both sides size-1 on different axes (= row × col → matrix)
#   - left-side scalar with non-commutative ops (`10.0 - a.lazy`,
#     `100.0 / a.lazy`, `2.0 ** a.lazy`)
#   - shape mismatch with no broadcast → ArgumentError raise
#
# Out of scope (= ArgumentError raise pinned):
#   - cross-ndim NumPy-style promotion (e.g. (3,4) + (4,)) — Q8 (a)
#     says bound-only.

$LOAD_PATH.unshift File.expand_path("../../ext", __dir__)
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "carray"
require "test/unit"

class TestLazyBinopP24 < Test::Unit::TestCase

  # ------------------------------------------------- same-ndim size-1 --

  def test_row_plus_col_broadcast_to_matrix
    # (1, 4) + (3, 1) → (3, 4)
    row = CArray.float64(1, 4).seq + 1
    col = CArray.float64(3, 1).seq * 10
    v = row.lazy + col
    e = row + col
    assert_equal [3, 4], v.dim
    assert_equal e.dump_binary, v.to_ca.dump_binary
  end

  def test_matrix_plus_col
    # (3, 4) + (3, 1) → (3, 4)
    a = CArray.float64(3, 4).seq
    col = CArray.float64(3, 1).seq + 100
    v = a.lazy + col
    e = a + col
    assert_equal [3, 4], v.dim
    assert_equal e.dump_binary, v.to_ca.dump_binary
  end

  def test_matrix_plus_row
    # (3, 4) + (1, 4) → (3, 4)
    a = CArray.float64(3, 4).seq
    row = CArray.float64(1, 4).seq + 50
    v = a.lazy + row
    e = a + row
    assert_equal [3, 4], v.dim
    assert_equal e.dump_binary, v.to_ca.dump_binary
  end

  def test_1d_size1_broadcast
    a = CArray.float64(8).seq
    b = CArray.float64(1).seq + 100
    v = a.lazy + b
    e = a + b
    assert_equal e.dump_binary, v.to_ca.dump_binary
  end

  # ------------------- left-side scalar with non-commutative op --

  def test_scalar_minus_array_non_commutative
    a = CArray.float64(3, 4).seq + 1.0
    v = 10.0 - a.lazy
    e = 10.0 - a
    assert_equal e.dump_binary, v.to_ca.dump_binary
  end

  def test_scalar_div_array_non_commutative
    a = CArray.float64(3, 4).seq + 1.0
    v = 100.0 / a.lazy
    e = 100.0 / a
    assert_equal e.dump_binary, v.to_ca.dump_binary
  end

  def test_scalar_pow_array
    a = CArray.float64(3, 4).seq
    v = 2.0 ** a.lazy
    e = 2.0 ** a
    assert_equal e.dump_binary, v.to_ca.dump_binary
  end

  def test_scalar_minus_lazy_chain
    a = CArray.float64(4, 5).seq + 1.0
    b = CArray.float64(4, 5).seq + 0.5
    v = 100.0 - (a.lazy + b)
    e = 100.0 - (a + b)
    assert_equal e.dump_binary, v.to_ca.dump_binary
  end

  # ------------------ shape mismatch / cross-ndim raises --

  def test_cross_ndim_raise
    # (3, 4) + (4,) — cross-ndim NumPy-style promotion is NOT a
    # deferred feature in CArray; it is a permanent design rejection
    # (user 2026-06-07 確定: spec aesthetic decision).  Users must
    # reshape explicitly.  Eager CArray rejects this with the same
    # "elements mismatch" error; lazy mirrors that contract.
    a = CArray.float64(3, 4).seq
    b = CArray.float64(4).seq
    assert_raise(ArgumentError) { (a.lazy + b).to_ca }
    # And explicit reshape unblocks:
    v = (a.lazy + b.reshape(1, 4))
    e = (a + b.reshape(1, 4))
    assert_equal e.dump_binary, v.to_ca.dump_binary
  end

  def test_same_ndim_incompatible_raise
    # (3, 4) + (5,) — different ndim too
    a = CArray.float64(3, 4).seq
    b = CArray.float64(5).seq
    assert_raise(ArgumentError) { (a.lazy + b).to_ca }
  end

  # ----------------------- broadcast preserves scratch=1/node --

  def test_broadcast_scratch_count_per_node
    a = CArray.float64(64, 64).seq
    b = CArray.float64(64, 1).seq + 10
    CABinOp.__reset_scratch_counter__
    CABinOp.__reset_materialise_counter__
    _ = (a.lazy + b).to_ca
    # 1 CABinOp ⇒ 1 scratch acquire (broadcasted right pulls into
    # a single same-output-shape scratch).
    assert_equal 1, CABinOp.__scratch_count__
    assert_equal 1, CABinOp.__materialise_count__
  end

  # ------- regression: same-shape and CScalar paths unchanged --

  def test_same_shape_regression
    a = CArray.float64(64).seq
    b = CArray.float64(64).seq + 1
    v = a.lazy + b
    e = a + b
    assert_equal e.dump_binary, v.to_ca.dump_binary
  end

  def test_array_plus_scalar_unchanged_from_p21
    a = CArray.float64(64).seq
    v = a.lazy + 7.5
    e = a + 7.5
    assert_equal e.dump_binary, v.to_ca.dump_binary
  end

  # -------------------- mask propagation through broadcast --

  def test_mask_propagation_with_broadcast
    a = CArray.float64(3, 4).seq
    a[1, 2] = UNDEF
    b = CArray.float64(3, 1).seq + 10
    b[2, 0] = UNDEF
    v = a.lazy + b
    out = v.to_ca
    assert_true out.has_mask?
    # Cell (1,2) is masked (from a), cells in row 2 are masked (from
    # broadcasted b[2,0])
    assert_kind_of UndefClass, out[1, 2]
    4.times { |j| assert_kind_of UndefClass, out[2, j], "row 2 col #{j}" }
  end
end

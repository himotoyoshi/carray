# CAMeld v0.1 stub — external-axis (meld_axis == 0) sanity pin.
# Design ref: devel/MEMO_CAMELD_SEGMENT_MAJOR_ENGINE.md
# Scope: constructor + uniform check + xfer_all (materialise) + xfer_index
# (scalar access) + structural xfer_stride (slice) + WRITE + uniform-case
# parity with CAStack+reshape.  Non-external-axis paths and non-structural
# strides are expected to raise NotImplementedError in v0.1.

require 'test/unit'
require 'carray'

class TestCAMeld < Test::Unit::TestCase

  def setup
    @a = CArray.int32(3, 4) { |i, j| 100 + i * 10 + j }
    @b = CArray.int32(5, 4) { |i, j| 200 + i * 10 + j }
    @c = CArray.int32(1, 4) { |i, j| 300 + i * 10 + j }
  end

  # ---------- construction ----------

  def test_construction_basic
    m = CAMeld.new([@a, @b, @c], axis: 0)
    assert_kind_of CAMeld, m
    assert_equal [9, 4], m.shape
    assert_equal 3, m.n_parents
    assert_equal 0, m.meld_axis
    assert_equal [0, 3, 8, 9], m.seg_offsets
    assert_equal "int32", m.data_type_name
  end

  def test_parents_accessor_preserves_identity
    m = CAMeld.new([@a, @b, @c], axis: 0)
    assert_same @a, m.parents[0]
    assert_same @b, m.parents[1]
    assert_same @c, m.parents[2]
  end

  def test_construction_single_parent
    m = CAMeld.new([@a], axis: 0)
    assert_equal [3, 4], m.shape
    assert_equal 1, m.n_parents
    assert_equal [0, 3], m.seg_offsets
  end

  # ---------- uniform check ----------

  def test_reject_non_meld_axis_mismatch
    x = CArray.int32(2, 3) { 0 }
    y = CArray.int32(2, 4) { 0 }
    assert_raise(ArgumentError) { CAMeld.new([x, y], axis: 0) }
  end

  def test_reject_dtype_mismatch
    x = CArray.int32(2, 3) { 0 }
    y = CArray.float64(2, 3) { 0 }
    assert_raise(ArgumentError) { CAMeld.new([x, y], axis: 0) }
  end

  def test_reject_ndim_mismatch
    x = CArray.int32(2, 3) { 0 }
    y = CArray.int32(2, 3, 1) { 0 }
    assert_raise(ArgumentError) { CAMeld.new([x, y], axis: 0) }
  end

  def test_reject_empty_parents
    assert_raise(ArgumentError) { CAMeld.new([], axis: 0) }
  end

  def test_reject_out_of_range_axis
    assert_raise(ArgumentError) { CAMeld.new([@a], axis: 5) }
  end

  # ---------- xfer_all (materialise) ----------

  def test_copy_matches_eager_concatenate
    m = CAMeld.new([@a, @b, @c], axis: 0)
    mat = m.copy
    assert_equal [9, 4], mat.shape
    expected = CArray.int32(9, 4) { |i, j|
      if    i < 3 then 100 + i * 10 + j
      elsif i < 8 then 200 + (i - 3) * 10 + j
      else             300 + (i - 8) * 10 + j
      end
    }
    assert_equal expected.to_a, mat.to_a
  end

  def test_uniform_meld_parity_with_castack_reshape
    a = CArray.int32(3, 4) { |i, j| i * 10 + j }
    b = CArray.int32(3, 4) { |i, j| 100 + i * 10 + j }
    c = CArray.int32(3, 4) { |i, j| 200 + i * 10 + j }
    meld = CAMeld.new([a, b, c], axis: 0).copy
    stack = CArray.meld([a, b, c])
    assert_equal stack.to_a, meld.to_a
  end

  # ---------- xfer_index (scalar access) ----------

  def test_scalar_access_crosses_segment_boundaries
    m = CAMeld.new([@a, @b, @c], axis: 0)
    assert_equal 100, m[0, 0]   # a[0, 0]
    assert_equal 123, m[2, 3]   # a[2, 3] = last row of segment 0
    assert_equal 200, m[3, 0]   # b[0, 0] = first row of segment 1
    assert_equal 243, m[7, 3]   # b[4, 3] = last row of segment 1
    assert_equal 302, m[8, 2]   # c[0, 2] = single row of segment 2
  end

  def test_scalar_access_out_of_range_raises
    m = CAMeld.new([@a, @b, @c], axis: 0)
    assert_raise(IndexError) { m[9, 0] }
  end

  # ---------- xfer_stride (structural slice) ----------

  def test_slice_crosses_segment_boundary
    m = CAMeld.new([@a, @b, @c], axis: 0)
    s = m[2..5, nil].copy
    expected = [
      [120, 121, 122, 123],   # a[2, *]
      [200, 201, 202, 203],   # b[0, *]
      [210, 211, 212, 213],   # b[1, *]
      [220, 221, 222, 223],   # b[2, *]
    ]
    assert_equal expected, s.to_a
  end

  def test_slice_within_single_segment
    m = CAMeld.new([@a, @b, @c], axis: 0)
    s = m[4..6, nil].copy
    expected = [
      [210, 211, 212, 213],
      [220, 221, 222, 223],
      [230, 231, 232, 233],
    ]
    assert_equal expected, s.to_a
  end

  def test_slice_full_range
    m = CAMeld.new([@a, @b, @c], axis: 0)
    assert_equal m.copy.to_a, m[0..8, nil].copy.to_a
  end

  # ---------- WRITE path (sync back to parents) ----------

  def test_full_assign_writes_back_to_parents
    a = CArray.int32(2, 3) { 0 }
    b = CArray.int32(3, 3) { 0 }
    m = CAMeld.new([a, b], axis: 0)
    m[] = CArray.int32(5, 3) { |i, j| i * 10 + j }
    assert_equal [[0, 1, 2], [10, 11, 12]], a.to_a
    assert_equal [[20, 21, 22], [30, 31, 32], [40, 41, 42]], b.to_a
  end

  def test_slice_assign_across_segment_boundary
    c = CArray.int32(2, 3) { 0 }
    d = CArray.int32(3, 3) { 0 }
    v = CAMeld.new([c, d], axis: 0)
    v[1..3, nil] = -1
    assert_equal [[0, 0, 0], [-1, -1, -1]], c.to_a
    assert_equal [[-1, -1, -1], [-1, -1, -1], [0, 0, 0]], d.to_a
  end

  # ---------- internal-axis paths (meld_axis != 0) ----------

  def test_internal_axis_materialise
    a = CArray.int32(3, 2) { |i, j| 10 * i + j }
    b = CArray.int32(3, 4) { |i, j| 100 + 10 * i + j }
    c = CArray.int32(3, 1) { |i, j| 200 + 10 * i + j }
    m = CArray.meld(a, b, c, axis: 1)
    assert_equal 1, m.meld_axis
    assert_equal [3, 7], m.shape
    mat = m.copy
    expected = CArray.int32(3, 7)
    expected[nil, 0..1] = a
    expected[nil, 2..5] = b
    expected[nil, 6..6] = c
    assert_equal expected.to_a, mat.to_a
  end

  def test_internal_axis_scalar_access
    a = CArray.int32(3, 2) { |i, j| 10 * i + j }
    b = CArray.int32(3, 4) { |i, j| 100 + 10 * i + j }
    m = CArray.meld(a, b, axis: 1)
    assert_equal a[0, 0], m[0, 0]
    assert_equal a[2, 1], m[2, 1]
    assert_equal b[0, 0], m[0, 2]      # first cell of segment 1
    assert_equal b[2, 3], m[2, 5]      # last cell
  end

  def test_internal_axis_structural_slice
    a = CArray.int32(3, 2) { |i, j| 10 * i + j }
    b = CArray.int32(3, 4) { |i, j| 100 + 10 * i + j }
    c = CArray.int32(3, 1) { |i, j| 200 + 10 * i + j }
    m = CArray.meld(a, b, c, axis: 1)
    s = m[nil, 1..4].copy
    expected = CArray.int32(3, 7)
    expected[nil, 0..1] = a
    expected[nil, 2..5] = b
    expected[nil, 6..6] = c
    assert_equal expected[nil, 1..4].to_a, s.to_a
  end

  def test_internal_axis_partial_slab_pstrides_regression
    # Regression: pstrides was computed from p->dim instead of pcounts,
    # so a partial-slab request (pcounts[i] < p->dim[i]) let the parent
    # write past the slab buf.  Reproducer: internal-axis meld with a
    # slice that trims cols and non-zero row starts.
    a = CArray.int32(3, 4) { |i, j| 10 * i + j }
    b = CArray.int32(3, 4) { |i, j| 100 + 10 * i + j }
    m = CArray.meld(a, b, axis: 1)                # shape [3, 8], ma=1
    s = m[1..2, 2..5].copy                          # partial: rows [1,2], cols [2,5)
    expected = CArray.int32(3, 8)
    expected[nil, 0..3] = a
    expected[nil, 4..7] = b
    assert_equal expected[1..2, 2..5].to_a, s.to_a
  end

  def test_internal_axis_write_syncs_to_parents
    aa = CArray.int32(2, 2) { 0 }
    bb = CArray.int32(2, 3) { 0 }
    v = CArray.meld(aa, bb, axis: 1)
    v[] = CArray.int32(2, 5) { |i, j| i * 5 + j }
    assert_equal [[0, 1], [5, 6]], aa.to_a
    assert_equal [[2, 3, 4], [7, 8, 9]], bb.to_a
  end

  # ---------- meld_reduce fast path (per-parent decompose) ----------
  # Fast path for decomposable reductions along the meld axis, matching
  # SRC_ATTACH results within eps-close (SIMD reduce license) or exact
  # (min/max).  See lib/carray/meld_reduce.rb and
  # devel/MEMO_CAMELD_SEGMENT_MAJOR_ENGINE.md §8 for the spike outcome.

  def build_float_meld
    a = CArray.float64(3, 4) { |i, j| 1.0 + i * 4 + j * 0.1 }
    b = CArray.float64(5, 4) { |i, j| 100.0 + i * 4 + j * 0.1 }
    c = CArray.float64(1, 4) { |i, j| 300.0 + j * 0.1 }
    [CAMeld.new([a, b, c], axis: 0), CArray.float64(9, 4).tap { |e|
      [a, b, c].each_with_index.inject(0) { |off, (p, _)| e[off...off+p.dim[0], nil] = p; off + p.dim[0] }
    }]
  end

  def test_meld_axis_sum_matches_eager
    m, eager = build_float_meld
    diff = m.sum(axis: 0).to_a.zip(eager.sum(axis: 0).to_a).map { |a,b| (a-b).abs }.max
    assert(diff < 1e-10, "sum(axis: meld_axis) diverges by #{diff}")
  end

  def test_meld_axis_mean_matches_eager
    m, eager = build_float_meld
    diff = m.mean(axis: 0).to_a.zip(eager.mean(axis: 0).to_a).map { |a,b| (a-b).abs }.max
    assert(diff < 1e-10, "mean(axis: meld_axis) diverges by #{diff}")
  end

  def test_meld_axis_min_exact_match
    m, eager = build_float_meld
    assert_equal eager.min(axis: 0).to_a, m.min(axis: 0).to_a
  end

  def test_meld_axis_max_exact_match
    m, eager = build_float_meld
    assert_equal eager.max(axis: 0).to_a, m.max(axis: 0).to_a
  end

  def test_flat_sum_matches_eager
    m, eager = build_float_meld
    assert_in_delta eager.sum, m.sum, 1e-10
  end

  def test_flat_mean_matches_eager
    m, eager = build_float_meld
    assert_in_delta eager.mean, m.mean, 1e-10
  end

  def test_negative_axis_kwarg_dispatches_to_fast_path
    m, eager = build_float_meld
    # -2 on shape [9, 4] == 0 == meld_axis, should hit fast path and match
    diff = m.mean(axis: -2).to_a.zip(eager.mean(axis: -2).to_a).map { |a,b| (a-b).abs }.max
    assert(diff < 1e-10)
  end

  def test_non_meld_axis_falls_through_to_super
    m, eager = build_float_meld
    # axis 1 is non-meld -- super path (SRC_ATTACH), must still match
    diff = m.mean(axis: 1).to_a.zip(eager.mean(axis: 1).to_a).map { |a,b| (a-b).abs }.max
    assert(diff < 1e-10)
  end

  # ---------- CArray.meld / #meld surface ----------

  def test_meld_class_method_splat
    v = CArray.meld(@a, @b, @c, axis: 0)
    assert_kind_of CAMeld, v
    assert_equal [9, 4], v.shape
  end

  def test_meld_class_method_single_array_arg
    v = CArray.meld([@a, @b, @c], axis: 0)
    assert_kind_of CAMeld, v
    assert_equal [9, 4], v.shape
  end

  def test_meld_uniform_returns_cameld
    u = CArray.int32(3, 4) { |i, j| i * 10 + j }
    v = CArray.meld(u, u, u, axis: 0)
    assert_kind_of CAMeld, v
    assert_equal [9, 4], v.shape
  end

  def test_meld_instance_method
    v = @a.meld(@b, @c)
    assert_kind_of CAMeld, v
    assert_equal [9, 4], v.shape
  end

  def test_meld_instance_default_axis
    x = CArray.int32(2, 3) { |i, j| i * 3 + j }
    y = CArray.int32(4, 3) { |i, j| 10 + i * 3 + j }
    assert_equal [6, 3], x.meld(y).shape
  end

  def test_meld_content_matches_eager
    v = CArray.meld(@a, @b, @c, axis: 0)
    expected = CArray.int32(9, 4) { |i, j|
      if    i < 3 then 100 + i * 10 + j
      elsif i < 8 then 200 + (i - 3) * 10 + j
      else             300 + (i - 8) * 10 + j
      end
    }
    assert_equal expected.to_a, v.to_a
  end

  def test_meld_negative_axis
    v = CArray.meld(@a, @b, @c, axis: -2)
    assert_equal 0, v.meld_axis
  end

  def test_meld_dispatches_to_reduce_fast_path
    # Result is CAMeld, so mean(axis: 0) must take the decompose fast path
    # (correctness == eager).  Perf pinned separately in devel/bench.
    a = CArray.float64(3, 5) { |i, j| i * 5.0 + j }
    b = CArray.float64(2, 5) { |i, j| 100.0 + i * 5.0 + j }
    v = CArray.meld(a, b, axis: 0)
    eager = CArray.float64(5, 5)
    eager[0..2, nil] = a
    eager[3..4, nil] = b
    diff = v.mean(axis: 0).to_a.zip(eager.mean(axis: 0).to_a).map { |x, y| (x - y).abs }.max
    assert(diff < 1e-10)
  end

  def test_meld_empty_raises
    assert_raise(ArgumentError) { CArray.meld }
    assert_raise(ArgumentError) { CArray.meld([]) }
  end

  def test_meld_instance_no_others_raises
    assert_raise(ArgumentError) { @a.meld }
  end

  def test_meld_shape_mismatch_raises
    x = CArray.int32(2, 3) { 0 }
    y = CArray.int32(3, 4) { 0 }
    assert_raise(ArgumentError) { CArray.meld(x, y, axis: 0) }
  end

  def test_meld_dtype_mismatch_raises
    # View semantic requires same dtype; use CArray.concatenate for auto-cast.
    x = CArray.int32(2, 3) { 0 }
    y = CArray.float64(2, 3) { 0 }
    assert_raise(ArgumentError) { CArray.meld(x, y, axis: 0) }
  end

  # ---------- non-meld-axis reduce (per-parent decompose + concat) ----------

  def build_random_meld
    a = CArray.float64(3, 4) { |i, j| (i * 4 + j) * 0.7 + 1 }
    b = CArray.float64(5, 4) { |i, j| (100 + i * 4 + j) * 0.3 }
    c = CArray.float64(1, 4) { |i, j| 200.0 + j }
    eager = CArray.float64(9, 4)
    off = 0
    [a, b, c].each { |p| eager[off...off + p.dim[0], nil] = p; off += p.dim[0] }
    [CAMeld.new([a, b, c], axis: 0), eager]
  end

  def test_non_meld_axis_sum_matches_eager
    m, eager = build_random_meld
    diff = m.sum(axis: 1).to_a.zip(eager.sum(axis: 1).to_a).map { |x, y| (x - y).abs }.max
    assert(diff < 1e-10, "sum(axis:1) diverges by #{diff}")
  end

  def test_non_meld_axis_mean_matches_eager
    m, eager = build_random_meld
    diff = m.mean(axis: 1).to_a.zip(eager.mean(axis: 1).to_a).map { |x, y| (x - y).abs }.max
    assert(diff < 1e-10, "mean(axis:1) diverges by #{diff}")
  end

  def test_non_meld_axis_min_exact_match
    m, eager = build_random_meld
    assert_equal eager.min(axis: 1).to_a, m.min(axis: 1).to_a
  end

  def test_non_meld_axis_max_exact_match
    m, eager = build_random_meld
    assert_equal eager.max(axis: 1).to_a, m.max(axis: 1).to_a
  end

  def test_non_meld_axis_returns_entity
    # CArray#mean(axis:) returns entity; the decompose fast path uses `.copy`
    # to materialise the intermediate CAMeld view for that contract.
    m, _ = build_random_meld
    result = m.mean(axis: 1)
    refute_kind_of CAMeld, result
    refute_kind_of CAView, result
  end

  # ---------- variance family (Welford combine along meld_axis) ----------

  def build_variance_meld
    a = CArray.float64(4, 3) { |i, j| (i * 3 + j) * 0.7 + 0.1 }
    b = CArray.float64(6, 3) { |i, j| (10 + i * 3 + j) * 0.4 + 0.5 }
    eager = CArray.float64(10, 3)
    eager[0..3, nil] = a
    eager[4..9, nil] = b
    [CAMeld.new([a, b], axis: 0), eager]
  end

  def test_variance_meld_axis_welford_close
    m, eager = build_variance_meld
    diff = m.variance(axis: 0).to_a.zip(eager.variance(axis: 0).to_a).map { |x, y| (x - y).abs / (x.abs + 1e-30) }.max
    assert(diff < 1e-10, "variance(axis:meld) Welford diverges by rel_err #{diff}")
  end

  def test_variancep_meld_axis_welford_close
    m, eager = build_variance_meld
    diff = m.variancep(axis: 0).to_a.zip(eager.variancep(axis: 0).to_a).map { |x, y| (x - y).abs / (x.abs + 1e-30) }.max
    assert(diff < 1e-10)
  end

  def test_stddev_meld_axis_welford_close
    m, eager = build_variance_meld
    diff = m.stddev(axis: 0).to_a.zip(eager.stddev(axis: 0).to_a).map { |x, y| (x - y).abs / (x.abs + 1e-30) }.max
    assert(diff < 1e-10)
  end

  def test_stddevp_meld_axis_welford_close
    m, eager = build_variance_meld
    diff = m.stddevp(axis: 0).to_a.zip(eager.stddevp(axis: 0).to_a).map { |x, y| (x - y).abs / (x.abs + 1e-30) }.max
    assert(diff < 1e-10)
  end

  def test_variance_non_meld_axis_exact_match
    m, eager = build_variance_meld
    assert_equal eager.variance(axis: 1).to_a, m.variance(axis: 1).to_a
  end

  def test_stddev_non_meld_axis_exact_match
    m, eager = build_variance_meld
    assert_equal eager.stddev(axis: 1).to_a, m.stddev(axis: 1).to_a
  end

  def test_variance_flat_welford_close
    m, eager = build_variance_meld
    diff = (m.variance - eager.variance).abs / (eager.variance.abs + 1e-30)
    assert(diff < 1e-10)
  end

  def test_stddev_flat_welford_close
    m, eager = build_variance_meld
    diff = (m.stddev - eager.stddev).abs / (eager.stddev.abs + 1e-30)
    assert(diff < 1e-10)
  end

  def test_empty_parent_mean_does_not_produce_nan
    # A zero-length parent contributes nothing and must not corrupt the
    # non-empty parent's mean.
    a = CArray.float64(0, 3) { 0 }
    b = CArray.float64(4, 3) { |i, j| (i + 1) * 10.0 + j }
    m = CArray.meld(a, b, axis: 0)
    diff = m.mean(axis: 0).to_a.zip(b.mean(axis: 0).to_a).map { |x, y| (x - y).abs }.max
    assert(diff < 1e-12)
  end

  def test_all_empty_parents_mean_returns_undef
    # No contributors → mean is undefined → super produces UNDEF per
    # CLAUDE.md "reduction は寄与ゼロで raise しない (identity or UNDEF)".
    e1 = CArray.float64(0, 3) { 0 }
    e2 = CArray.float64(0, 3) { 0 }
    m = CArray.meld(e1, e2, axis: 0)
    result = m.mean(axis: 0)
    assert result.has_mask?
    assert result.mask.to_a.all? { |x| x != 0 }
  end

  # ---------- nested CAMeld flatten (reviewer follow-up round 2) ----------

  def test_nested_meld_same_axis_flattens
    a = CArray.float64(2, 3) { |i, j| i * 3 + j }
    b = CArray.float64(3, 3) { |i, j| 10 + i * 3 + j }
    c = CArray.float64(1, 3) { |i, j| 100 + j }
    inner = CArray.meld(a, b, axis: 0)   # 2-parent CAMeld
    outer = CArray.meld(inner, c, axis: 0)
    # inner absorbed into outer's parent list — one CAMeld, three parents.
    assert_equal 3, outer.n_parents
    assert_equal [0, 2, 5, 6], outer.seg_offsets
    # Non-CAMeld parents preserved identity; the absorbed pair is a and b.
    assert_same a, outer.parents[0]
    assert_same b, outer.parents[1]
    assert_same c, outer.parents[2]
  end

  def test_nested_meld_different_axis_not_flattened
    a = CArray.float64(2, 3) { |i, j| i * 3 + j }
    b = CArray.float64(2, 4) { |i, j| 10 + i * 4 + j }
    inner = CArray.meld(a, b, axis: 1)   # meld_axis=1
    other = CArray.float64(4, 7) { 0 }
    outer = CArray.meld(inner, other, axis: 0)
    # meld_axis differs (0 vs 1) → inner not flattened.
    assert_equal 2, outer.n_parents
    assert_kind_of CAMeld, outer.parents[0]
  end

  # ---------- dtype-heterogeneous meld raises (view semantic) ----------

  def test_dtype_heterogeneous_meld_raises
    # View semantic requires same dtype at construction.  Caller either casts
    # the pieces themselves, or uses CArray.concatenate (eager) for auto-cast.
    a = CArray.int32(2, 2) { |i, j| i * 2 + j }
    b = CArray.float64(3, 2) { |i, j| 100.0 + i * 2 + j }
    assert_raise(ArgumentError) { CArray.meld(a, b, axis: 0) }
    # Pre-cast then meld works.
    m = CArray.meld(a.to_type(:float64), b, axis: 0)
    assert_equal "float64", m.data_type_name
    assert_equal [5, 2], m.shape
  end

  # ---------- dup / clone semantics ----------

  def test_dup_preserves_parent_identity
    a = CArray.int32(2, 3) { |i, j| i * 3 + j }
    b = CArray.int32(3, 3) { |i, j| 100 + i * 3 + j }
    m = CArray.meld(a, b, axis: 0)
    d = m.dup
    assert_same a, d.parents[0]
    assert_same b, d.parents[1]
    assert_equal m.copy.to_a, d.copy.to_a
    # dup produces a distinct CAMeld object.
    refute_same m, d
  end

  # ---------- single-parent degenerate case ----------

  def test_single_parent_reduce_and_write
    a = CArray.float64(4, 3) { |i, j| i * 3 + j * 0.1 }
    m = CArray.meld(a, axis: 0)
    assert_equal 1, m.n_parents
    assert_equal a.to_a, m.copy.to_a
    diff = m.mean(axis: 0).to_a.zip(a.mean(axis: 0).to_a).map { |x, y| (x - y).abs }.max
    assert(diff < 1e-12)
    m[0, 0] = -1.0
    assert_equal(-1.0, a[0, 0])   # write reaches parent (view semantic)
  end

  # ---------- GC survival ----------

  def test_survives_gc_compact
    a = CArray.int32(3, 4) { |i, j| i * 4 + j }
    b = CArray.int32(2, 4) { |i, j| 100 + i * 4 + j }
    m = CArray.meld(a, b, axis: 0)
    GC.start
    GC.compact if GC.respond_to?(:compact)
    GC.start
    assert_equal 2, m.n_parents
    assert_same a, m.parents[0]
    assert_equal [5, 4], m.shape
    # Materialise round-trip still correct after GC.
    eager = CArray.int32(5, 4)
    eager[0..2, nil] = a
    eager[3..4, nil] = b
    assert_equal eager.to_a, m.copy.to_a
  end

  def test_variance_falls_through_when_parent_too_short
    # Welford needs n >= 2 for sample variance; a parent with 1 row triggers
    # super (SRC_ATTACH path handles it correctly).
    a = CArray.float64(1, 3) { |_, j| j.to_f }
    b = CArray.float64(3, 3) { |i, j| (i + j).to_f }
    m = CAMeld.new([a, b], axis: 0)
    eager = CArray.float64(4, 3)
    eager[0..0, nil] = a
    eager[1..3, nil] = b
    diff = m.variance(axis: 0).to_a.zip(eager.variance(axis: 0).to_a).map { |x, y| (x - y).abs }.max
    assert(diff < 1e-10)
  end

  def test_ragged_meld_axis_reduce_matches_eager
    # ragged first-axis lengths, uniform tail
    a = CArray.float64(2, 3) { |i, j| i * 3 + j }
    b = CArray.float64(4, 3) { |i, j| 100 + i * 3 + j }
    c = CArray.float64(1, 3) { |i, j| 200 + j }
    m = CAMeld.new([a, b, c], axis: 0)
    eager = CArray.float64(7, 3)
    off = 0
    [a, b, c].each { |p| eager[off...off+p.dim[0], nil] = p; off += p.dim[0] }
    %i[sum mean].each do |op|
      diff = m.send(op, axis: 0).to_a.zip(eager.send(op, axis: 0).to_a).map { |x,y| (x-y).abs }.max
      assert(diff < 1e-10, "#{op}(axis: 0) ragged diverges by #{diff}")
    end
    assert_equal eager.min(axis: 0).to_a, m.min(axis: 0).to_a
    assert_equal eager.max(axis: 0).to_a, m.max(axis: 0).to_a
  end

  # ---------- CArray#concatenate (instance, eager auto-cast) --------------

  def test_instance_concatenate_matches_class_method
    a = CArray.float64(2, 3) { |i, j| i * 3 + j }
    b = CArray.float64(3, 3) { |i, j| 10 + i * 3 + j }
    c = CArray.float64(1, 3) { |i, j| 100 + j }
    r_inst  = a.concatenate(b, c, axis: 0)
    r_class = CArray.concatenate([a, b, c], axis: 0)
    assert_equal [6, 3], r_inst.shape
    assert(r_inst == r_class)
  end

  def test_instance_concatenate_is_eager_not_view
    a = CArray.float64(2, 3) { 1 }
    b = CArray.float64(2, 3) { 2 }
    r = a.concatenate(b, axis: 0)
    refute_kind_of CAMeld, r
    # eager: mutating a source must not affect the concatenated result.
    a[0, 0] = 99.0
    assert_equal 1.0, r[0, 0]
  end

  def test_instance_concatenate_auto_casts_dtype
    i = CArray.int32(2, 3) { 1 }
    f = CArray.float64(2, 3) { 2.5 }
    r = i.concatenate(f, axis: 0)
    assert_equal :float64, r.data_type
  end

  def test_instance_concatenate_axis_kwarg
    a = CArray.float64(2, 3) { |i, j| i * 3 + j }
    b = CArray.float64(2, 4) { |i, j| 10 + i * 4 + j }
    r = a.concatenate(b, axis: 1)
    assert_equal [2, 7], r.shape
  end

  def test_instance_concatenate_no_others_raises
    a = CArray.float64(2, 3) { 0 }
    assert_raises(ArgumentError) { a.concatenate(axis: 0) }
  end
end

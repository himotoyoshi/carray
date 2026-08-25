# CAStack — outer-axis-only stack view tests
# PROPOSAL_CASTACK.md S.1 acceptance criteria (AC1.1 - AC1.8)
# Design ref: devel/MEMO_CASTACK_DESIGN.md

require 'test/unit'
require 'carray'

class TestCAStack < Test::Unit::TestCase

  def setup
    @a = CArray.float64(3, 4) { |i, j| i * 10 + j }
    @b = CArray.float64(3, 4) { |i, j| 100 + i * 10 + j }
    @c = CArray.float64(3, 4) { |i, j| 200 + i * 10 + j }
  end

  # ------------ AC1.1: construction + shape + data_type ------------

  def test_construction_basic
    s = CArray.stack([@a, @b, @c])
    assert_kind_of CAStack, s
    assert_equal [3, 3, 4], s.shape
    assert_equal "float64", s.data_type_name
    assert_equal 3, s.n_parents
    assert_equal 3, s.parents.size
  end

  def test_parents_accessor_introspection
    s = CArray.stack([@a, @b, @c])
    # introspectability: parents Array preserves identity (project memo)
    assert_same @a, s.parents[0]
    assert_same @b, s.parents[1]
    assert_same @c, s.parents[2]
  end

  def test_construction_single_parent
    s = CArray.stack([@a])
    assert_equal [1, 3, 4], s.shape
    assert_equal 1, s.n_parents
  end

  # ------------ AC1.2: uniform constraint (MEMO §3.2) ------------

  def test_uniform_raise_on_shape_mismatch
    bad = CArray.float64(3, 5) { 0 }
    assert_raise(ArgumentError) { CArray.stack([@a, bad]) }
  end

  def test_data_type_mismatch_auto_promotes
    # 3.0 (post promote_list landed): mixed primitive dtypes no longer
    # raise.  CArray.stack -> promote_list -> result_type chooses the
    # common dtype, and wrap_readonly coerces each element.  Use
    # CAStack.new(list) for the raw "must be uniform" contract.
    bad = CArray.int32(3, 4) { 0 }
    s = CArray.stack([@a, bad])
    assert_equal "float64", s.data_type_name   # @a is float64, int32 -> float64
    # Raw constructor still enforces uniformity:
    assert_raise(ArgumentError) { CAStack.new([@a, bad]) }
  end

  def test_uniform_raise_on_ndim_mismatch
    bad = CArray.float64(3, 4, 2) { 0 }
    assert_raise(ArgumentError) { CArray.stack([@a, bad]) }
  end

  # ------------ AC1.3 / AC1.4: scalar + region access ------------

  def test_scalar_access_via_xfer_index
    s = CArray.stack([@a, @b, @c])
    assert_equal 0.0,   s[0, 0, 0]
    assert_equal 123.0, s[1, 2, 3]
    assert_equal 223.0, s[2, 2, 3]
  end

  def test_single_parent_region_slice
    # AC1.3: counts[0] == 1 case — conditional fold_stride path
    s = CArray.stack([@a, @b, @c])
    sliced = s[1, 0..1, 0..2].to_ca
    assert_equal [2, 3], sliced.shape
    assert_equal [[100.0, 101.0, 102.0], [110.0, 111.0, 112.0]], sliced.to_a
  end

  def test_multi_parent_region_slice
    # AC1.4: counts[0] > 1 case — K-fold xfer_stride dispatch
    s = CArray.stack([@a, @b, @c])
    sliced = s[0..2, 0, 0..1].to_ca
    assert_equal [3, 2], sliced.shape
    assert_equal [[0.0, 1.0], [100.0, 101.0], [200.0, 201.0]], sliced.to_a
  end

  def test_partial_axis0_range_slice
    # multi-parent slice starting from middle
    pieces = (0...5).map { |k| CArray.float64(10) { |i| k * 100 + i } }
    ss = CArray.stack(pieces)
    sliced = ss[1..3, 0..2].to_ca
    assert_equal [3, 3], sliced.shape
    assert_equal [[100, 101, 102], [200, 201, 202], [300, 301, 302]],
                 sliced.to_a.map { |r| r.map(&:to_i) }
  end

  # ------------ AC1.5: horizontal mask propagation (MEMO §3.9) ------------

  def test_horizontal_mask_propagation
    a = CArray.float64(3) { |i| i }
    b = CArray.float64(3) { |i| 10 + i }
    c = CArray.float64(3) { |i| 20 + i }
    assert_false a.has_mask?
    assert_false b.has_mask?
    assert_false c.has_mask?

    s = CArray.stack([a, b, c])
    s.send(:__create_mask__)

    # CAStack-side horizontal propagation: all parents' roots gain mask
    assert_true a.has_mask?
    assert_true b.has_mask?
    assert_true c.has_mask?
    assert_true s.has_mask?
    assert_kind_of CAStackMask, s.mask
  end

  def test_mask_class_self_similar
    s = CArray.stack([@a, @b, @c])
    s.send(:__create_mask__)
    # mask CAStack uses same class (self-similar)
    assert_kind_of CAStack, s.mask
  end

  # ------------ AC1.6: K-axis reduce (LOOP_INTERCHANGE 合流) ------------

  def test_reduce_on_k_axis_via_materialise
    s = CArray.stack([@a, @b, @c])
    # @a[i,j]=10i+j, @b[i,j]=100+10i+j, @c[i,j]=200+10i+j
    # mean = (@a + @b + @c) / 3 = 100 + 10i + j
    m = s.to_ca.mean(axis: 0)
    assert_equal [3, 4], m.shape
    expected = CArray.float64(3, 4) { |i, j| 100.0 + 10 * i + j }
    expected.shape[0].times do |i|
      expected.shape[1].times do |j|
        assert_in_delta expected[i, j], m[i, j], 1e-12
      end
    end
  end

  # ------------ AC1.7: attach round-trip via xfer_all materialise ------------

  def test_to_ca_round_trip
    s = CArray.stack([@a, @b, @c])
    mat = s.to_ca
    assert_kind_of CArray, mat
    assert_equal [3, 3, 4], mat.shape
    # spot-check all parents
    3.times do |i|
      4.times do |j|
        assert_equal @a[i, j], mat[0, i, j]
        assert_equal @b[i, j], mat[1, i, j]
        assert_equal @c[i, j], mat[2, i, j]
      end
    end
  end

  # ------------ s.append(parent) flat append (MEMO §3.3) ------------

  def test_stack_append_returns_new_instance
    s = CArray.stack([@a, @b])
    d = CArray.float64(3, 4) { 999.0 }
    s2 = s.append(d)
    refute_same s, s2
    assert_equal 2, s.n_parents     # original unmutated
    assert_equal 3, s2.n_parents
    assert_equal [3, 3, 4], s2.shape
    assert_equal 999.0, s2[2, 0, 0]
  end

  def test_carray_stack_method_on_plain_carray
    # a.stack(b) for plain CArray = new CAStack(a, b)
    s = @a.stack(@b)
    assert_kind_of CAStack, s
    assert_equal 2, s.n_parents
    assert_equal @a, s.parents[0]
    assert_equal @b, s.parents[1]
  end

  def test_appended_stack_remains_flat_depth_1
    # MEMO §3.3: flat append, stack depth always 1
    s1 = CArray.stack([@a, @b])
    s2 = s1.append(@c)
    assert_equal 3, s2.n_parents
    # s2's parents are all leaf CArrays, not nested CAStack
    s2.parents.each do |p|
      refute_kind_of CAStack, p
    end
  end

  # ------------ AC1.8: kernel_iterator 透過 (= sum / mean等が通る) ------------

  def test_kernel_iterator_transparent_sum
    s = CArray.stack([@a, @b, @c])
    # sum() over all elements via materialise
    total = s.to_ca.sum
    expected = @a.sum + @b.sum + @c.sum
    assert_in_delta expected, total, 1e-9
  end

  def test_kernel_iterator_direct_reduce_on_view
    # AC1.8 真の充足: view.mean / view.sum / view.max を direct (= to_ca 経由なし)
    # で呼べる。SRC_ATTACH classify 経由で kernel_iterator が CAStack を受ける。
    s = CArray.stack([@a, @b, @c])
    direct_sum  = s.sum
    via_to_ca   = s.to_ca.sum
    assert_in_delta via_to_ca, direct_sum, 1e-9

    direct_mean = s.mean(axis: 0)
    via_to_ca_m = s.to_ca.mean(axis: 0)
    assert_equal via_to_ca_m.shape, direct_mean.shape
    direct_mean.shape[0].times do |i|
      direct_mean.shape[1].times do |j|
        assert_in_delta via_to_ca_m[i, j], direct_mean[i, j], 1e-9
      end
    end
  end

  # ---- PROPOSAL_CASTACK_LOOP_INTERCHANGE rev4 (= ALIAS_STACK tile cache) ----
  # CAStack + CA_SLAB_AXES + slab_axes == [0] (= K-axis reduce) engages the
  # CA_ITER_ALIAS_STACK direct-per-parent-ptr-access path with internal
  # tile cache unconditionally (rev4 撤廃 the 256 MiB size-threshold gate
  # and its CARRAY_CASTACK_DIRECT_THRESHOLD_MB env var; engage condition
  # is now CAStack identity + no-mask + axis:0 + READ).

  def test_castack_direct_ptr_path_correctness_K_small
    s = CArray.stack([@a, @b, @c])   # K=3, (3,3,4)
    eager = s.to_ca.mean(axis: 0)
    via   = s.mean(axis: 0)
    assert_equal eager.shape, via.shape
    eager.shape[0].times do |i|
      eager.shape[1].times do |j|
        assert_in_delta eager[i, j], via[i, j], 1e-12
      end
    end
  end

  def test_castack_direct_ptr_path_K_larger_bit_exact_sum
    parents = (0...20).map { |k|
      CArray.float64(8, 6) { |i, j| (k + 1).to_f * (i + 1) * (j + 1) }
    }
    s = CArray.stack(parents)
    eager = s.to_ca.sum(axis: 0)
    via   = s.sum(axis: 0)
    # bit-exact at this scale (small K, exact f64)
    assert_equal eager.to_a, via.to_a
  end

  def test_castack_direct_ptr_path_K_larger_mean
    parents = (0...20).map { |k|
      CArray.float64(8, 6) { |i, j| k * 1000.0 + i * 10 + j }
    }
    s = CArray.stack(parents)
    assert_equal [20, 8, 6], s.shape
    eager = s.to_ca.mean(axis: 0)
    via   = s.mean(axis: 0)
    assert_equal [8, 6], via.shape
    8.times do |i|
      6.times do |j|
        assert_in_delta eager[i, j], via[i, j], 1e-12
      end
    end
  end

  def test_castack_non_zero_axis_uses_fallback
    # POST P.2 Case A (2026-06-18): axes != [0] now engages CA_ITER_ALIAS_
    # STACK_OUTER_K alias path (parent ptr aliased per outer iter, no
    # whole-view materialise).  Pre-P.2 this went to SRC_ATTACH fallback;
    # legacy test name retained for git blame continuity.
    parents = (0...4).map { |k|
      CArray.float64(5, 7) { |i, j| k * 100.0 + i * 10 + j }
    }
    s = CArray.stack(parents)
    eager = s.to_ca.mean(axis: 2)
    via   = s.mean(axis: 2)
    assert_equal eager.shape, via.shape
    eager.shape[0].times do |k|
      eager.shape[1].times do |i|
        assert_in_delta eager[k, i], via[k, i], 1e-12
      end
    end
  end

  def test_castack_masked_stack_uses_fallback
    # axis 0 + mask combination: STACK path skips mask, falls back to
    # SRC_ATTACH whole-view.  Verify correctness through the fallback.
    a = CArray.float64(3, 4) { |i, j| i * 10 + j }
    a[0, 0] = UNDEF
    b = CArray.float64(3, 4) { |i, j| 100 + i * 10 + j }
    s = CArray.stack([a, b])
    assert s.has_mask?
    eager = s.to_ca.mean(axis: 0)
    via   = s.mean(axis: 0)
    eager.shape[0].times do |i|
      eager.shape[1].times do |j|
        assert_in_delta eager[i, j], via[i, j], 1e-12
      end
    end
  end

  def test_castack_default_correctness_small_K
    # K=3 small-K case via the same (now unconditional) STACK + tile cache
    # path.  Verifies correctness on the smallest engage shape.
    s = CArray.stack([@a, @b, @c])
    eager = s.to_ca.mean(axis: 0)
    via   = s.mean(axis: 0)
    eager.shape[0].times do |i|
      eager.shape[1].times do |j|
        assert_in_delta eager[i, j], via[i, j], 1e-12
      end
    end
  end

  def test_kernel_iterator_direct_element_wise
    # view + scalar binop が direct で動く (= kernel_iterator SRC_ATTACH 経路)
    s = CArray.stack([@a, @b, @c])
    doubled_direct = (s * 2.0).to_ca
    doubled_via    = (s.to_ca * 2.0)
    assert_equal doubled_via.shape, doubled_direct.shape
    doubled_via.shape[0].times do |i|
      doubled_via.shape[1].times do |j|
        doubled_via.shape[2].times do |k|
          assert_in_delta doubled_via[i, j, k], doubled_direct[i, j, k], 1e-9
        end
      end
    end
  end

  # ------------ regression: K >= 128 (int8_t overflow in setup loops) ------------

  def test_construction_k_128_threshold
    # Was: int8_t loop counter in ca_stack_check_uniform / ca_stack_setup
    # wrapped at K=128, causing OOB parent[-128..-1] access (SEGV with mask,
    # spurious uniform-violation raise without mask).
    parents = (0...128).map { |kk| CArray.float64(4, 5) { |i, j| kk * 1000.0 + i * 10 + j } }
    s = CArray.stack(parents)
    assert_equal 128, s.n_parents
    assert_equal [128, 4, 5], s.shape
  end

  def test_construction_k_200_masked_no_segv
    k = 200
    parents = (0...k).map { |kk|
      a = CArray.float64(8, 6) { |i, j| kk * 1_000_000.0 + i * 1000.0 + j }
      a[:eq, kk * 1_000_000.0].mask = 1
      a
    }
    s = CArray.stack(parents)
    assert_equal k, s.n_parents
    assert_equal [k, 8, 6], s.shape
  end

  def test_construction_k_200_unmasked
    k = 200
    parents = (0...k).map { |kk| CArray.float64(4, 5) { |i, j| kk * 1000.0 + i * 10 + j } }
    s = CArray.stack(parents)
    assert_equal k, s.n_parents
    assert_equal [k, 4, 5], s.shape
  end

  # ============================================================
  # PROPOSAL_CASTACK_XFER_OPT_LAYERING P.2 Case A
  # ============================================================
  # CA_ITER_ALIAS_STACK_OUTER_K: slab_axes excludes axis 0 (= K-axis
  # in outer iter), engine aliases parents[k]->ptr + parent_off
  # directly.  Verified: bit-exact match with eager, axis 1, axis 2,
  # multi-axis slab, mask-present cases.

  def test_case_a_axis_1_bit_exact
    parents = (0...5).map { |k|
      CArray.float64(4, 6) { |i, j| k * 100.0 + i * 10 + j }
    }
    s = CArray.stack(parents)
    eager = s.to_ca.mean(axis: 1)
    via   = s.mean(axis: 1)
    assert_equal eager.shape, via.shape
    eager.each_index do |*idx|
      assert_in_delta eager[*idx], via[*idx], 1e-12
    end
  end

  def test_case_a_axis_2_bit_exact
    parents = (0...5).map { |k|
      CArray.float64(4, 6) { |i, j| k * 100.0 + i * 10 + j }
    }
    s = CArray.stack(parents)
    eager = s.to_ca.mean(axis: 2)
    via   = s.mean(axis: 2)
    assert_equal eager.shape, via.shape
    eager.each_index do |*idx|
      assert_in_delta eager[*idx], via[*idx], 1e-12
    end
  end

  def test_case_a_multi_axis_slab_bit_exact
    # slab_axes = [1, 2], outer = [0] = K-axis only.
    parents = (0...4).map { |k|
      CArray.float64(3, 5) { |i, j| k * 100.0 + i * 10 + j }
    }
    s = CArray.stack(parents)
    eager = s.to_ca.mean(axis: [1, 2])
    via   = s.mean(axis: [1, 2])
    assert_equal eager.shape, via.shape
    eager.each_index do |*idx|
      assert_in_delta eager[*idx], via[*idx], 1e-12
    end
  end

  def test_case_a_mask_alias_bit_exact_axis_1
    # Masked parents → horizontal propagation → CAStack mask present.
    # Case A aliases parents[k]->mask->ptr alongside data ptr.
    parents = (0...4).map { |k|
      a = CArray.float64(3, 5) { |i, j| k * 100.0 + i * 10 + j }
      a[k % 3, (k + 1) % 5] = UNDEF
      a
    }
    s = CArray.stack(parents)
    assert s.has_mask?
    eager = s.to_ca.mean(axis: 1)
    via   = s.mean(axis: 1)
    assert_equal eager.shape, via.shape
    if eager.has_mask?
      assert_equal eager.mask.to_a, via.mask.to_a
    end
    eager.each_index do |*idx|
      next if eager.mask && eager.mask[*idx]
      assert_in_delta eager[*idx], via[*idx], 1e-12
    end
  end

  def test_case_a_mask_alias_bit_exact_axis_2
    parents = (0...4).map { |k|
      a = CArray.float64(3, 5) { |i, j| k * 100.0 + i * 10 + j }
      a[k % 3, (k + 1) % 5] = UNDEF
      a
    }
    s = CArray.stack(parents)
    assert s.has_mask?
    eager = s.to_ca.mean(axis: 2)
    via   = s.mean(axis: 2)
    assert_equal eager.shape, via.shape
    eager.each_index do |*idx|
      next if eager.mask && eager.mask[*idx]
      assert_in_delta eager[*idx], via[*idx], 1e-12
    end
  end

  def test_case_a_sum_axis_1_bit_exact
    # Verify Case A engages on sum kernel too (= not mean-specific).
    parents = (0...5).map { |k|
      CArray.float64(4, 6) { |i, j| k * 100.0 + i * 10 + j }
    }
    s = CArray.stack(parents)
    eager = s.to_ca.sum(axis: 1)
    via   = s.sum(axis: 1)
    assert_equal eager.shape, via.shape
    eager.each_index do |*idx|
      assert_in_delta eager[*idx], via[*idx], 1e-12
    end
  end

  def test_case_a_does_not_engage_when_axis_0_in_slab
    # Sanity: when slab includes axis 0 (= reduce(axis: 0)), Case A
    # detection (`!in_slab[0]`) is false → falls through to rev3
    # CA_ITER_ALIAS_STACK Case B path (still correct).
    parents = (0...5).map { |k|
      CArray.float64(4, 6) { |i, j| k * 100.0 + i * 10 + j }
    }
    s = CArray.stack(parents)
    eager = s.to_ca.mean(axis: 0)
    via   = s.mean(axis: 0)
    assert_equal eager.shape, via.shape
    eager.each_index do |*idx|
      assert_in_delta eager[*idx], via[*idx], 1e-12
    end
  end

  def test_case_a_k_200_no_segv_or_alloc_explosion
    # Regression: K=200 with masked parents must not crash even at
    # large output cell count.  Validates parent attach lifecycle +
    # mask ptr cache cleanup in finish.
    k = 200
    parents = (0...k).map { |kk|
      a = CArray.float64(8, 6) { |i, j| kk * 1000.0 + i * 1.0 + j * 0.1 }
      a[kk % 8, (kk + 1) % 6] = UNDEF
      a
    }
    s = CArray.stack(parents)
    assert s.has_mask?
    via = s.mean(axis: 1)
    eager = s.to_ca.mean(axis: 1)
    assert_equal eager.shape, via.shape
    eager.each_index do |*idx|
      next if eager.mask && eager.mask[*idx]
      assert_in_delta eager[*idx], via[*idx], 1e-10
    end
  end

  # ------------ F1 regression: CATranspose(CAStack) must not raise ------------
  # A permuting chain hands xfer_stride a reordered front axis whose extent
  # may exceed n_parents.  The non-structural per-cell fallback handles it
  # correctly; the structural axis-0 bounds check must not gate that branch.
  # Bug: raised IndexError when permuted front-axis extent > K.

  def test_transpose_over_stack_front_axis_exceeds_k_no_raise
    # K=2, parents (3,4) -> stack (2,3,4) -> transpose (3,4,2):
    # front axis extent 3 > K=2 used to raise.
    s = CArray.stack([@a, @b])
    got = nil
    assert_nothing_raised { got = s.transpose(1, 2, 0).to_ca }
    assert_equal [3, 4, 2], got.shape
    ref = CArray.float64(3, 4, 2)
    [@a, @b].each_with_index do |src, k|
      3.times { |i| 4.times { |j| ref[i, j, k] = src[i, j] } }
    end
    assert_equal ref.to_a, got.to_a
  end

  def test_transpose_over_stack_propagates_mask
    am = @a.to_ca; am[1, 1] = UNDEF
    got = CArray.stack([am, @b]).transpose(1, 2, 0).to_ca
    assert_equal true, got.is_masked[1, 1, 0]   # masked cell carried through
    assert_equal false, got.is_masked[0, 0, 1]   # unmasked elsewhere
  end

  def test_transpose_over_stack_front_axis_equals_k
    # Coincidental size (front extent == K) previously "worked"; still must.
    a = CArray.float64(2, 5) { |i, j| i * 10 + j }
    b = CArray.float64(2, 5) { |i, j| 100 + i * 10 + j }
    s = CArray.stack([a, b])                    # (2,2,5)
    got = s.transpose(1, 2, 0).to_ca          # (2,5,2)
    ref = CArray.float64(2, 5, 2)
    [a, b].each_with_index do |src, k|
      2.times { |i| 5.times { |j| ref[i, j, k] = src[i, j] } }
    end
    assert_equal ref.to_a, got.to_a
  end

  # ------------ pre-existing xfer_stride bug: inner-axis subrange ------------
  # CAStack.xfer_stride passed the dst (counts-based) row-major strides to each
  # parent as if they were source strides.  They coincide with the parent
  # layout only when every inner axis is full; an inner subrange made the
  # source walk read a contiguous run instead of the strided slab.

  def setup_grid_stack(k = 6)
    parents = (0...k).map { |kk|
      CArray.float64(6, 5) { |i, j| kk * 1000.0 + i * 10 + j }
    }
    [parents, CArray.stack(parents), ground_truth_stack(parents)]
  end

  def ground_truth_stack(parents)
    out = CArray.float64(parents.size, *parents[0].shape)
    parents.each_with_index { |p, kk| p.each_index { |*ix| out[kk, *ix] = p[*ix] } }
    out
  end

  def test_xfer_stride_inner_subrange_multi_parent
    _, s, g = setup_grid_stack
    assert_equal g[2..4, nil, 1..3].to_ca.to_a, s[2..4, nil, 1..3].to_ca.to_a
    assert_equal g[2..4, 1..2, nil].to_ca.to_a, s[2..4, 1..2, nil].to_ca.to_a
    assert_equal g[2..4, 1..2, 1..3].to_ca.to_a, s[2..4, 1..2, 1..3].to_ca.to_a
    assert_equal g[2..4, nil, nil].to_ca.to_a,   s[2..4, nil, nil].to_ca.to_a
  end

  # ------------ F2: ndim-drop partial materialise (bridge) ------------
  # Integer indexing drops an axis, so the leaf view is ndim < CAStack.ndim.
  # The compose-fold consumer reinserts the dropped axis as degenerate count=1
  # so the partial-materialise xfer_stride path runs (touched parents only)
  # instead of materialising the whole K-parent stack.

  def test_f2_drop_cases_bit_exact
    _, s, g = setup_grid_stack
    {
      "K-drop full"     => [s[3, nil, nil],   g[3, nil, nil]],
      "K-drop lon-subr" => [s[3, nil, 1..3],  g[3, nil, 1..3]],
      "K-drop lat-subr" => [s[3, 1..2, nil],  g[3, 1..2, nil]],
      "inner lat-drop"  => [s[nil, 2, nil],   g[nil, 2, nil]],
      "lat-drop+lonsub" => [s[nil, 2, 1..3],  g[nil, 2, 1..3]],
      "lon-drop"        => [s[nil, nil, 3],   g[nil, nil, 3]],
      "double-drop 1D"  => [s[3, 1, nil],     g[3, 1, nil]],
    }.each do |name, (view, ref)|
      assert_equal ref.to_ca.to_a, view.to_ca.to_a, "F2 #{name}"
    end
  end

  def test_f2_drop_propagates_mask
    e = (0...8).map { |kk| CArray.float64(6, 5) { |i, j| kk * 1000.0 + i * 10 + j } }
    s = CArray.stack(e)
    s[3, 1, 2] = UNDEF        # creates the stack mask + marks one cell
    assert_equal true, s[3, nil, nil].to_ca.is_masked[1, 2]    # K-drop
    assert_equal false, s[3, nil, nil].to_ca.is_masked[0, 0]
    assert_equal true, s[nil, 1, nil].to_ca.is_masked[3, 2]    # inner-drop, full K
    assert_equal true, s[3, 1, nil].to_ca.is_masked[2]         # 1-D
  end

  # ------------ F2 guard: reshape/flatten must NOT take the bridge ------------
  # A flatten matches the innermost native stride but overflows the axis;
  # the bridge's bound check rejects it -> 2-pass fallback keeps it correct.

  def test_f2_flatten_reshape_stays_correct
    _, s, g = setup_grid_stack(4)
    assert_equal g.reshape(4 * 6 * 5).to_a, s.reshape(4 * 6 * 5).to_a
    assert_equal g[2, nil, nil].reshape(30).to_a, s[2, nil, nil].reshape(30).to_a
  end

  # ------------ multi-parent category: upward parent->stack propagation ------------
  # CA_FLAG_MULTI_PARENTS makes generic single-parent routines fold over all
  # parents: mask presence = ANY, read-only = ANY, root/ancestors = STOP,
  # value/mask-array identity = STOP (not inherited across the fan-out).

  def test_mask_detected_when_parent_masked_before_stack
    pm = (0...4).map { |kk| CArray.float64(3, 3) { |i, j| kk * 100.0 + i * 10 + j } }
    pm[2][0, 0] = UNDEF
    s = CArray.stack(pm)
    assert s.has_mask?                                  # ANY parent masked
    got = s.to_ca
    assert_equal true, got.is_masked[2, 0, 0]
    assert_equal false, got.is_masked[0, 0, 0]
  end

  def test_mask_detected_when_parent_masked_after_stack_alias
    pe = (0...4).map { |kk| CArray.float64(3, 3) { |i, j| kk * 100.0 + i * 10 + j } }
    s = CArray.stack(pe)
    pe[2][1, 1] = UNDEF                                 # alias mutation post-construction
    assert s.has_mask?
    assert_equal true, s[2, nil, nil].to_ca.is_masked[1, 1]
  end

  def test_clean_stack_has_no_spurious_mask
    s = CArray.stack((0...4).map { CArray.float64(2, 2) { 0.0 } })
    refute s.has_mask?
    refute s.to_ca.has_mask?
  end

  def test_readonly_any_fold
    w = (0...3).map { CArray.float64(2, 2) { 0.0 } }
    refute CArray.stack(w).read_only?                  # all writable
    r = (0...3).map { CArray.float64(2, 2) { 0.0 } }
    r[1].freeze                                         # one read-only parent
    assert CArray.stack(r).read_only?                 # ANY read-only -> stack read-only
  end

  def test_root_and_ancestors_stop_at_multiparent
    s = CArray.stack((0...3).map { CArray.float64(2, 2) { 0.0 } })
    assert_same s, s.root_array                         # boundary, not parents[0]'s root
    assert_equal [CAStack], s.ancestors.map(&:class)
  end

  def test_identity_flags_not_inherited_across_fanout
    s = CArray.stack((0...3).map { CArray.float64(2, 2) { 0.0 } })
    refute s.value_array?                               # stack is not "the .value of" anything
    refute s.mask_array?
    s[0, 0, 0] = UNDEF
    assert_kind_of CAStackMask, s.mask
    assert s.mask.mask_array?                           # the mask itself is flagged directly
  end

  # ------------ fold_stride box containment (vs counts[0]==1) ------------
  # fold_stride must fold to a single parent only when the request's byte box
  # fits in one parent, NOT when output axis 0 happens to have extent 1.  After
  # a transpose, axis 0 is a parent axis; a size-1 leading axis with a
  # multi-parent K axis elsewhere used to fold wrongly -> silent data loss.

  def test_fold_stride_size1_leading_axis_keeps_multiparent
    pm = (0...4).map { |k| CArray.float64(3, 5) { |i, j| k * 100.0 + i * 10 + j } }
    t = CArray.stack(pm).transpose(1, 0, 2)             # (3,4,5), K at output pos 1
    got = t[2..2, 0..3, 2..4].to_ca                      # H extent 1, K extent 4
    assert_equal [1, 4, 3], got.shape
    4.times { |k| 3.times { |j| assert_equal pm[k][2, 2 + j], got[0, k, j] } }
  end

  # ------------ K-relocation xfer_stride (K at any axis, not just outermost) --
  # A transpose that moves K off the outermost axis but keeps a contiguous inner
  # block delivers per-parent strided blocks instead of per-cell; K innermost
  # stays per-cell.  This pins correctness across all K positions + sub-blocks.

  def test_k_relocation_all_positions_bit_exact
    pm = (0...4).map { |k| CArray.float64(3, 5) { |i, j| k * 100.0 + i * 10 + j } }
    s = CArray.stack(pm)                                # (4,3,5)
    [[0, 1, 2], [1, 0, 2], [1, 2, 0], [2, 0, 1], [0, 2, 1], [2, 1, 0]].each do |perm|
      v = s.transpose(*perm)
      got = v.to_ca
      got.each_index { |*idx| assert_equal v[*idx], got[*idx], "perm=#{perm.inspect} idx=#{idx.inspect}" }
    end
  end

  def test_k_relocation_subblocks_and_put
    pm = (0...4).map { |k| CArray.float64(3, 5) { |i, j| k * 100.0 + i * 10 + j } }
    t = CArray.stack(pm).transpose(1, 0, 2)
    [[1..2, 0..2, 1..3], [0..1, 1..3, 0..4], [2..2, 0..3, 2..4]].each do |r|
      v = t[*r]; got = v.to_ca
      got.each_index { |*idx| assert_equal v[*idx], got[*idx] }
    end
    # PUT (write-back) through the relocation path reaches the right parents
    e = (0...3).map { CArray.float64(2, 4) { 0.0 } }
    w = CArray.stack(e).transpose(1, 0, 2)              # (2,3,4)
    w[] = CArray.float64(2, 3, 4) { |i, k, j| 100 + i * 10 + k + j * 0.1 }
    assert_in_delta 112.3, e[2][1, 3], 1e-9
    assert_in_delta 100.0, e[0][0, 0], 1e-9
  end

  # ------------ per-cell access through a CAStride view over a CAStack ------------
  # ca_stride_func_xfer_index delegates an aligned single cell to its cold parent
  # via the parent's INDEX path (addr2index + xfer_index), not the addr path
  # (fetch_addr -> xfer_addrs), which for a CAStack would O(K) bucket-scan per cell.
  # This pins the value correctness of that delegate (read and write).

  def test_single_cell_access_over_transpose_stack
    planes = (0...4).map { |k| CArray.float64(3, 5) { |i, j| k * 100.0 + i * 10 + j } }
    v = CArray.stack(planes, axis: -1)         # CATranspose(CAStack), shape (3,5,4)
    assert_equal [3, 5, 4], v.shape
    3.times { |i| 5.times { |j| 4.times { |k|
      assert_equal planes[k][i, j], v[i, j, k]
    } } }
  end

  def test_single_cell_write_through_transpose_stack
    e = (0...3).map { CArray.float64(2, 4) { 0.0 } }
    v = CArray.stack(e, axis: -1)              # (2,4,3) view aliasing the entities
    v[1, 2, 0] = 99.0
    assert_equal 99.0, e[0][1, 2]        # write reaches parent 0
    assert_equal 0.0, e[1][1, 2]         # other parents untouched
  end

end

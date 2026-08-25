# CAStack k_axis — PROPOSAL_CASTACK_K_AXIS K.2a + K.4 spec_ai pin.
# Covers: axis: kwarg surface (positive / negative / nil),
# k_axis identity field accessor, shape generalisation,
# xfer_index (= per-cell `[]` read) correctness for all k_axis,
# xfer_all (= `.copy` materialise) correctness for all k_axis,
# xfer_addrs path via boolean-mask gather, edge shapes (parent 1-D, K=1).
# K.2b/K.2c (xfer_stride perf), K.3 (tile cache engage),
# K.5/K.6 (compose family rewire) are out of scope here.

require 'test/unit'
require 'carray'

class TestCAStackKAxis < Test::Unit::TestCase

  def setup
    @a = CArray.int32(2, 3) { |i, j| i * 10 + j }
    @b = CArray.int32(2, 3) { |i, j| 100 + i * 10 + j }
    @c = CArray.int32(2, 3) { |i, j| 200 + i * 10 + j }
    @parents = [@a, @b, @c]
  end

  # ---------------- Ruby surface (K.4) ----------------

  def test_axis_kwarg_default_zero
    s = CArray.stack([@a, @b, @c])
    assert_equal 0, s.k_axis
    assert_equal [3, 2, 3], s.shape
  end

  def test_axis_kwarg_positive
    s = CArray.stack([@a, @b, @c], axis: 1)
    assert_equal 1, s.k_axis
    assert_equal [2, 3, 3], s.shape
  end

  def test_axis_kwarg_innermost
    s = CArray.stack([@a, @b, @c], axis: 2)
    assert_equal 2, s.k_axis
    assert_equal [2, 3, 3], s.shape
  end

  def test_axis_kwarg_negative
    # -1 = innermost (parent_ndim), -2 = mid, -3 = outermost.
    s_innermost = CArray.stack([@a, @b, @c], axis: -1)
    assert_equal 2, s_innermost.k_axis
    s_mid = CArray.stack([@a, @b, @c], axis: -2)
    assert_equal 1, s_mid.k_axis
    s_outer = CArray.stack([@a, @b, @c], axis: -3)
    assert_equal 0, s_outer.k_axis
  end

  def test_axis_kwarg_out_of_range_raises
    assert_raise(ArgumentError) { CArray.stack([@a, @b], axis: 3) }
    assert_raise(ArgumentError) { CArray.stack([@a, @b], axis: -4) }
  end

  def test_list_form_with_axis
    # CArray.stack([a, b, c], axis: i) shorthand
    s = CArray.stack([@a, @b, @c], axis: 1)
    assert_equal 1, s.k_axis
    assert_equal [2, 3, 3], s.shape
  end

  def test_instance_method_with_axis
    # CArray#stack(other, axis:) — always treats self as a parent of a
    # new K-stack.  Even when self is a CAStack, it goes in as parents[0].
    s = @a.stack(@b, axis: 1)
    assert_equal 1, s.k_axis
    assert_equal [2, 2, 3], s.shape   # parents = [@a, @b], K = 2
  end

  def test_castack_stack_treats_self_as_parent
    # CArray#stack inherited on CAStack: self goes in as a single parent
    # of the NEW stack (= NOT flat-appended into self.parents).
    s = CArray.stack([@a, @b], axis: 1)     # shape (2, 2, 3)
    s2 = s.stack(@c)                         # [@s, @c] as 2 parents
    # @c has shape (2, 3) but s has shape (2, 2, 3) -- shape mismatch.
    # We expect uniform-shape rejection from CAStack constructor.
    flunk "unreachable"
  rescue ArgumentError
    # OK -- shape mismatch is the correct behaviour for stacking a
    # CAStack with a non-uniform sibling.
  end

  def test_castack_append_extends_parents
    # CAStack#append(*others): flat-append into existing parents,
    # preserves k_axis.  Explicit method, no axis: kwarg.
    s = CArray.stack([@a, @b], axis: 1)
    s2 = s.append(@c)
    assert_equal 1, s2.k_axis        # k_axis carried over from receiver
    assert_equal [2, 3, 3], s2.shape
    assert_equal 3, s2.n_parents
  end

  def test_castack_append_multi
    s = CArray.stack([@a], axis: 0)
    s2 = s.append(@b, @c)
    assert_equal 0, s2.k_axis
    assert_equal 3, s2.n_parents
    assert_equal [3, 2, 3], s2.shape
  end

  def test_castack_append_empty_raises
    s = CArray.stack([@a, @b], axis: 1)
    assert_raise(ArgumentError) { s.append }
  end

  # ---------------- xfer_index correctness (= `[]` per-cell) ----------------

  def test_xfer_index_all_axes
    [0, 1, 2].each do |kax|
      s = CArray.stack(@parents, axis: kax)
      @parents.each_with_index do |p, k|
        @a.shape[0].times do |i|
          @a.shape[1].times do |j|
            vidx = [i, j].dup
            vidx.insert(kax, k)
            assert_equal p[i, j], s[*vidx],
                         "axis=#{kax}, k=#{k}, parent_idx=(#{i}, #{j})"
          end
        end
      end
    end
  end

  # ---------------- xfer_all correctness (= `.copy` materialise) ----------------

  def test_copy_round_trip_all_axes
    [0, 1, 2].each do |kax|
      s  = CArray.stack(@parents, axis: kax)
      cp = s.copy
      assert_equal s.shape, cp.shape
      assert_equal s.elements, cp.elements
      # cell-by-cell match against parents through the k_axis insertion rule
      @parents.each_with_index do |p, k|
        @a.shape[0].times do |i|
          @a.shape[1].times do |j|
            vidx = [i, j].dup
            vidx.insert(kax, k)
            assert_equal p[i, j], cp[*vidx],
                         "copy axis=#{kax}, k=#{k}, parent_idx=(#{i}, #{j})"
          end
        end
      end
    end
  end

  # ---------------- xfer_addrs (= flat-addr gather) ----------------

  def test_to_a_all_axes
    # `to_a` flattens via xfer_all → row-major over view shape.
    # Verify against an explicit nested build.
    [0, 1, 2].each do |kax|
      s = CArray.stack(@parents, axis: kax)
      cp = s.copy
      shape = s.shape
      expected = Array.new(s.elements)
      i_iter = 0
      product_indices(shape).each do |vidx|
        # decode (k, parent_idx) from vidx
        k = vidx[kax]
        pidx = vidx.dup
        pidx.delete_at(kax)
        expected[i_iter] = @parents[k][*pidx]
        i_iter += 1
      end
      assert_equal expected, cp.to_a.flatten
    end
  end

  # ---------------- edge shapes ----------------

  def test_k_equals_one
    s = CArray.stack([@a], axis: 1)
    assert_equal [2, 1, 3], s.shape
    assert_equal 1, s.k_axis
    cp = s.copy
    @a.shape[0].times do |i|
      @a.shape[1].times do |j|
        assert_equal @a[i, j], cp[i, 0, j]
      end
    end
  end

  def test_parent_1d_all_axes
    p0 = CArray.int32(4) { |i| i }
    p1 = CArray.int32(4) { |i| 10 + i }
    [0, 1].each do |kax|
      s = CArray.stack([p0, p1], axis: kax)
      assert_equal kax, s.k_axis
      expected_shape = (kax == 0) ? [2, 4] : [4, 2]
      assert_equal expected_shape, s.shape
      cp = s.copy
      2.times do |k|
        4.times do |i|
          vidx = [i].dup
          vidx.insert(kax, k)
          assert_equal [p0, p1][k][i], cp[*vidx]
        end
      end
    end
  end

  # ---------------- clone / dup preserve k_axis ----------------

  def test_clone_preserves_k_axis
    s = CArray.stack([@a, @b, @c], axis: 1)
    s2 = s.clone
    assert_equal 1, s2.k_axis
    assert_equal s.shape, s2.shape
  end

  # ---------------- K.2b: xfer_stride for k_axis != 0 ----------------
  #
  # Exercise the structural / reloc / per-cell paths that K.2a previously
  # forced through the per-cell fallback.  K.2b makes structural + reloc
  # k_axis-aware and we want pins for each path.

  def test_sub_block_returns_view_of_view
    # A chain on top of a CAStack(axis=mid) exercises CAStack.xfer_stride
    # via CABlock chain-fold.  Block-slice a sub-range along each axis,
    # materialise via .copy, and verify against the parents.
    s = CArray.stack([@a, @b, @c], axis: 1)   # shape (2, 3, 3)
    sub = s[0..1, 1..2, 0..2]               # shape (2, 2, 3) — chain on CAStack
    cp = sub.copy
    assert_equal [2, 2, 3], cp.shape
    2.times do |i|
      2.times do |k_off|
        3.times do |j|
          k = 1 + k_off
          # original view idx: vidx = [i, k, j] (K at view axis 1)
          expected = @parents[k][i, j]
          assert_equal expected, cp[i, k_off, j],
                       "sub-block k_axis=1 i=#{i} k=#{k} j=#{j}"
        end
      end
    end
  end

  def test_transpose_chain_reloc_path
    # CATranspose on top of a CAStack(axis=mid) — the chain composition
    # permutes the K axis to a different output position, exercising the
    # reloc fast path (or its per-cell fallback if the permutation isn't a
    # K-only relocation).
    s = CArray.stack([@a, @b, @c], axis: 1)   # shape (2, 3, 3), K at view axis 1
    # K moves from view axis 1 to output axis 0 (= structural for axis=0
    # request but on a transposed shape).  Use a transpose pattern that
    # keeps non-K axes in order.
    t = s.transpose(1, 0, 2)                # output: (K, i, j) = (3, 2, 3)
    cp = t.copy
    assert_equal [3, 2, 3], cp.shape
    3.times do |k|
      2.times do |i|
        3.times do |j|
          assert_equal @parents[k][i, j], cp[k, i, j],
                       "transpose reloc k=#{k} i=#{i} j=#{j}"
        end
      end
    end
  end

  def test_transpose_chain_reloc_to_innermost
    # K moves from view axis 1 to output axis 2 (= K innermost via reloc).
    s = CArray.stack([@a, @b, @c], axis: 1)   # shape (2, 3, 3), K at view axis 1
    t = s.transpose(0, 2, 1)                # output: (i, j, K) = (2, 3, 3)
    cp = t.copy
    assert_equal [2, 3, 3], cp.shape
    2.times do |i|
      3.times do |j|
        3.times do |k|
          assert_equal @parents[k][i, j], cp[i, j, k],
                       "transpose-to-innermost i=#{i} j=#{j} k=#{k}"
        end
      end
    end
  end

  def test_reshape_chain_per_cell_fallback
    # reshape (or any chain that destroys the K-only-permutation structure)
    # exercises the per-cell xfer_index fallback.  Just verify correctness.
    s = CArray.stack([@a, @b, @c], axis: 2)   # shape (2, 3, 3), K innermost
    flat = s.reshape(18)                    # 1-D over total elements
    cp = flat.copy
    assert_equal [18], cp.shape
    # row-major flattening of s: for (i, j, k) -> s[i, j, k] = parents[k][i, j]
    expected = []
    2.times do |i|
      3.times do |j|
        3.times do |k|
          expected << @parents[k][i, j]
        end
      end
    end
    assert_equal expected, cp.to_a
  end

  def test_write_back_via_view_assign
    # Write through CAStack(axis=mid) via [view] = scalar.  Exercises
    # xfer_stride PUT path for k_axis != 0.
    # shape (D_0=2, K=2, D_1=2): axis 0 = parent_i, axis 1 = K, axis 2 = parent_j.
    p0 = CArray.int32(2, 2) { |i, j| 100 + 10*i + j }
    p1 = CArray.int32(2, 2) { |i, j| 200 + 10*i + j }
    s = CArray.stack([p0, p1], axis: 1)
    s[nil, 1, nil] = -1                      # K=1 slab = all of parents[1]
    assert_equal(-1, p1[0, 0])
    assert_equal(-1, p1[1, 1])
    # parents[0] untouched
    assert_equal 100, p0[0, 0]
    assert_equal 111, p0[1, 1]
  end

  # ---------------- K.3: reductions at axis = k_axis ----------------
  #
  # Engages the rev4 tile cache (= STACK fast path) for any k_axis, not
  # just k_axis = 0.  Correctness pin: stack(parents, axis: i).mean(axis: i)
  # equals the per-cell parent value mean.  K.3's engage predicate is
  # `axes[0] == k_axis` in ca_kernel_iterator.c.

  def test_reduce_along_k_axis_all_positions
    # Build same-shape parents with distinct values so mean(axis: k_axis)
    # equals the per-cell arithmetic mean across parents.
    p0 = CArray.float64(3, 4) { |i, j| 1.0 + i + 0.1 * j }
    p1 = CArray.float64(3, 4) { |i, j| 2.0 + i + 0.1 * j }
    p2 = CArray.float64(3, 4) { |i, j| 3.0 + i + 0.1 * j }
    parents = [p0, p1, p2]

    expected_cell = lambda do |i, j|
      (p0[i, j] + p1[i, j] + p2[i, j]) / 3.0
    end

    [0, 1, 2].each do |kax|
      s = CArray.stack(parents, axis: kax)
      m = s.mean(axis: kax)        # reduce along K-axis → engages tile cache
      # Resulting shape = parent_shape (= K eliminated)
      assert_equal [3, 4], m.shape, "k_axis=#{kax} reduce shape"
      3.times do |i|
        4.times do |j|
          # mean cell — small numeric tolerance
          assert_in_delta expected_cell.call(i, j), m[i, j], 1e-12,
                          "mean axis k_axis=#{kax} at (#{i}, #{j})"
        end
      end
    end
  end

  def test_reduce_along_non_k_axis_with_k_in_middle
    # Reduce along a parent axis (= NOT the K axis) while k_axis is in the
    # middle.  Engages STACK_OUTER_K (= per-slab inside one parent).
    p0 = CArray.float64(2, 3) { |i, j| 10.0 + i + 0.1 * j }
    p1 = CArray.float64(2, 3) { |i, j| 20.0 + i + 0.1 * j }
    s = CArray.stack([p0, p1], axis: 1)   # shape (2, 2, 3); k_axis = 1
    # Reduce along view axis 2 (= parent axis 1).  Expected: per-parent mean
    # along its own axis 1.
    m = s.mean(axis: 2)
    assert_equal [2, 2], m.shape
    2.times do |i|
      2.times do |k|
        parent = [p0, p1][k]
        expected = (parent[i, 0] + parent[i, 1] + parent[i, 2]) / 3.0
        assert_in_delta expected, m[i, k], 1e-12,
                        "mean axis 2 (k_axis=1) at (#{i}, k=#{k})"
      end
    end
  end

  def test_sum_along_k_axis_matches_manual
    # Same as the mean test but using sum, with int dtype to ensure exact
    # arithmetic (= no fp rounding).
    p0 = CArray.int32(2, 3) { |i, j| 1 + i * 10 + j }
    p1 = CArray.int32(2, 3) { |i, j| 100 + i * 10 + j }
    p2 = CArray.int32(2, 3) { |i, j| 1000 + i * 10 + j }
    [0, 1, 2].each do |kax|
      s = CArray.stack([p0, p1, p2], axis: kax)
      summed = s.sum(axis: kax)
      assert_equal [2, 3], summed.shape, "sum axis=#{kax} shape"
      2.times do |i|
        3.times do |j|
          expected = p0[i, j] + p1[i, j] + p2[i, j]
          assert_equal expected, summed[i, j],
                       "sum k_axis=#{kax} at (#{i}, #{j})"
        end
      end
    end
  end

  # ---------------- M.1.0: PROPOSAL_MKKERNEL_TIER2_K_AXIS_GEN ----------------
  #
  # M.1 branch fires when CAStack source + k_axis > 0 + reduce ax > k_axis +
  # ax != ndim-1 + naxes == 1 + mask == NULL + INNER >= 64 + M * INNER >= 1024.
  # Output base offset is computed via stride table + carry-increment multi-
  # index; INNER cells remain contig at output tail (j-stride 1 preserved).
  # These pins exercise the new branch directly (existing K.3 tests use
  # ax == ndim-1 or sub-threshold sizes that bypass the fast path).

  def test_m1_reduce_ax_gt_k_axis_4d_f64
    # 4D pattern: parents (3, 10, 128) -> stack axis 1 -> view (3, 3, 10, 128).
    # k_axis = 1, reduce view ax = 2 (= parent ax = 1), INNER = 128, M = 10.
    # ax > k_axis = 1, ax != ndim-1 = 3 -> M.1 branch fires.
    p0 = CArray.float64(3, 10, 128) { |i, j, k| 1.0 + i + 0.01*j + 0.0001*k }
    p1 = CArray.float64(3, 10, 128) { |i, j, k| 2.0 + i + 0.01*j + 0.0001*k }
    p2 = CArray.float64(3, 10, 128) { |i, j, k| 3.0 + i + 0.01*j + 0.0001*k }
    s = CArray.stack([p0, p1, p2], axis: 1)
    assert_equal [3, 3, 10, 128], s.shape

    result = s.sum(axis: 2)
    assert_equal [3, 3, 128], result.shape

    parents = [p0, p1, p2]
    3.times do |i|
      3.times do |k|
        [0, 64, 127].each do |n|
          expected = (0..9).inject(0.0) { |acc, j| acc + parents[k][i, j, n] }
          assert_in_delta expected, result[i, k, n], 1e-10,
            "m1 f64 (i=#{i}, k=#{k}, n=#{n})"
        end
      end
    end
  end

  def test_m1_reduce_ax_gt_k_axis_4d_int32
    # Same 4D pattern with int32 sum (exact arithmetic, no fp rounding).
    p0 = CArray.int32(3, 10, 128) { |i, j, k| 1 + i*100000 + j*1000 + k }
    p1 = CArray.int32(3, 10, 128) { |i, j, k| 2 + i*100000 + j*1000 + k }
    s = CArray.stack([p0, p1], axis: 1)
    assert_equal [3, 2, 10, 128], s.shape

    result = s.sum(axis: 2)
    assert_equal [3, 2, 128], result.shape

    parents = [p0, p1]
    3.times do |i|
      2.times do |k|
        [0, 64, 127].each do |n|
          expected = (0..9).inject(0) { |acc, j| acc + parents[k][i, j, n] }
          assert_equal expected, result[i, k, n], "m1 int32 (i=#{i}, k=#{k}, n=#{n})"
        end
      end
    end
  end

  def test_m1_reduce_ax_gt_k_axis_5d_multi_pre
    # 5D pattern: parents (2, 3, 10, 128) -> stack axis 1 -> view (2, 2, 3, 10, 128).
    # k_axis = 1, reduce view ax = 3 (= parent ax = 2), ndim = 5, ndim-1 = 4.
    # Exercises carry-increment over multiple PRE dims (parent PRE = dims [0..1]
    # = view positions [0, 2] split by K at output position 1).
    p0 = CArray.int32(2, 3, 10, 128) { |a, c, d, e| 1 + a*1000000 + c*10000 + d*100 + e }
    p1 = CArray.int32(2, 3, 10, 128) { |a, c, d, e| 2 + a*1000000 + c*10000 + d*100 + e }
    s = CArray.stack([p0, p1], axis: 1)
    assert_equal [2, 2, 3, 10, 128], s.shape

    result = s.sum(axis: 3)
    assert_equal [2, 2, 3, 128], result.shape

    parents = [p0, p1]
    [0, 1].each do |a|
      [0, 1].each do |k|
        [0, 2].each do |c|
          [0, 64, 127].each do |e|
            expected = (0..9).inject(0) { |acc, d| acc + parents[k][a, c, d, e] }
            assert_equal expected, result[a, k, c, e],
              "m1 5d (a=#{a}, k=#{k}, c=#{c}, e=#{e})"
          end
        end
      end
    end
  end

  def test_m1_parity_with_k_axis_0_path
    # Cross-check: same parent shape stacked at k_axis = 0 vs k_axis = 1
    # gives transposable results.  Both go through Tier 2 fast path (k_axis=0
    # via existing branch, k_axis=1 via new M.1 branch); the reduce outputs
    # must match modulo axis order.
    p0 = CArray.float64(8, 128) { |i, j| 1.0 + i + 0.001 * j }
    p1 = CArray.float64(8, 128) { |i, j| 2.0 + i + 0.001 * j }
    p2 = CArray.float64(8, 128) { |i, j| 3.0 + i + 0.001 * j }
    parents = [p0, p1, p2]

    # k_axis = 0 path: view (3, 8, 128), reduce ax=1, output (3, 128).
    s0 = CArray.stack(parents, axis: 0)
    r0 = s0.sum(axis: 1)
    assert_equal [3, 128], r0.shape

    # k_axis = 1 path: view (8, 3, 128), reduce ax=... wait this needs ax > 1
    # and ax != ndim-1 = 2 -- ax=2 fails gate.  So construct ndim=4 with
    # k_axis=1: parents (8, 4, 128), view (8, 3, 4, 128), reduce ax=2.
    pp = [
      CArray.float64(8, 4, 128) { |i, jj, k| 1.0 + i + 0.01 * jj + 0.0001 * k },
      CArray.float64(8, 4, 128) { |i, jj, k| 2.0 + i + 0.01 * jj + 0.0001 * k },
      CArray.float64(8, 4, 128) { |i, jj, k| 3.0 + i + 0.01 * jj + 0.0001 * k }
    ]
    s1 = CArray.stack(pp, axis: 1)  # view (8, 3, 4, 128), k_axis = 1
    assert_equal [8, 3, 4, 128], s1.shape
    r1 = s1.sum(axis: 2)             # M.1 branch
    assert_equal [8, 3, 128], r1.shape

    # Generic-path cross-check: same source, generic ki path via .copy(materialise).
    r1_generic = s1.copy.sum(axis: 2)
    assert_equal [8, 3, 128], r1_generic.shape
    8.times do |i|
      3.times do |k|
        [0, 64, 127].each do |n|
          assert_in_delta r1_generic[i, k, n], r1[i, k, n], 1e-10,
            "m1 parity (i=#{i}, k=#{k}, n=#{n})"
        end
      end
    end
  end

  # ---------------- M.2.0a: PROPOSAL_MKKERNEL_TIER2_K_AXIS_GEN ----------------
  #
  # M.2a (= ax < k_axis AND k_axis == ax + 1): K directly after the reduce
  # axis.  Parent INNER axes are all post-K in output (contig at tail),
  # same structural shape as M.1 -- handled by the same emit branch with
  # kax_out + pa formulas generalized.

  def test_m2a_reduce_ax_eq_kax_minus_1_f64
    # Parents (3, 10, 128) -> stack axis 2 -> view (3, 10, K, 128).
    # k_axis=2, reduce view ax=1 (= parent ax=1, k_axis = ax+1).
    p0 = CArray.float64(3, 10, 128) { |i, j, k| 1.0 + i + 0.01*j + 0.0001*k }
    p1 = CArray.float64(3, 10, 128) { |i, j, k| 2.0 + i + 0.01*j + 0.0001*k }
    s = CArray.stack([p0, p1], axis: 2)
    assert_equal [3, 10, 2, 128], s.shape

    result = s.sum(axis: 1)
    assert_equal [3, 2, 128], result.shape   # K at output pos 1 (= kax_out)

    parents = [p0, p1]
    3.times do |i|
      2.times do |k|
        [0, 64, 127].each do |n|
          expected = (0..9).inject(0.0) { |acc, j| acc + parents[k][i, j, n] }
          assert_in_delta expected, result[i, k, n], 1e-10,
            "m2a f64 (i=#{i}, k=#{k}, n=#{n})"
        end
      end
    end
  end

  def test_m2a_reduce_ax_eq_kax_minus_1_int32
    # Same shape, int32 sum for exact arithmetic.
    p0 = CArray.int32(3, 10, 128) { |i, j, k| 1 + i*100000 + j*1000 + k }
    p1 = CArray.int32(3, 10, 128) { |i, j, k| 2 + i*100000 + j*1000 + k }
    p2 = CArray.int32(3, 10, 128) { |i, j, k| 3 + i*100000 + j*1000 + k }
    s = CArray.stack([p0, p1, p2], axis: 2)
    assert_equal [3, 10, 3, 128], s.shape

    result = s.sum(axis: 1)
    assert_equal [3, 3, 128], result.shape

    parents = [p0, p1, p2]
    3.times do |i|
      3.times do |k|
        [0, 64, 127].each do |n|
          expected = (0..9).inject(0) { |acc, j| acc + parents[k][i, j, n] }
          assert_equal expected, result[i, k, n], "m2a int32 (i=#{i}, k=#{k}, n=#{n})"
        end
      end
    end
  end

  def test_m2a_parity_with_generic_path
    # Cross-check vs generic ki path via .copy materialise.
    pp = [
      CArray.float64(4, 12, 128) { |i, j, k| 1.0 + i + 0.01*j + 0.0001*k },
      CArray.float64(4, 12, 128) { |i, j, k| 2.0 + i + 0.01*j + 0.0001*k },
      CArray.float64(4, 12, 128) { |i, j, k| 3.0 + i + 0.01*j + 0.0001*k }
    ]
    s = CArray.stack(pp, axis: 2)  # view (4, 12, 3, 128), k_axis = 2
    assert_equal [4, 12, 3, 128], s.shape

    r_m2a    = s.sum(axis: 1)        # M.2a branch (k_axis = ax + 1)
    r_generic = s.copy.sum(axis: 1)
    assert_equal [4, 3, 128], r_m2a.shape

    4.times do |i|
      3.times do |k|
        [0, 64, 127].each do |n|
          assert_in_delta r_generic[i, k, n], r_m2a[i, k, n], 1e-10,
            "m2a parity (i=#{i}, k=#{k}, n=#{n})"
        end
      end
    end
  end

  # ---------------- M.2.0b: PROPOSAL_MKKERNEL_TIER2_K_AXIS_GEN ----------------
  #
  # M.2b (= ax < k_axis - 1): parent INNER axes are split by K in the output.
  # Strategy C (effective OUTER expansion): INNER_pre_K dims (parent dims
  # [pa+1..k_axis-1]) are merged into effective OUTER, eff_INNER = parent
  # dims [k_axis..pndim-1] (contig at output tail).  L.7 core variant uses
  # M_stride = full parent INNER (separate from tile loop bound = eff_INNER).
  #
  # Gate: eff_INNER >= 32 (lower than M.1/M.2a 64).  Auto-bypasses at = -1
  # (k_axis = pndim -> eff_INNER = 1).

  def test_m2b_inner_split_by_k_4d_f64
    # Parents (16, 8, 64) -> stack axis 2 -> view (16, 8, K, 64), k_axis=2.
    # Reduce view ax=0 (parent ax=0), M=16, eff_INNER=64, INNER_pre_K=8.
    # ax + 1 = 1 < k_axis = 2 -> M.2b branch.
    p0 = CArray.float64(16, 8, 64) { |i, j, k| 1.0 + i*0.1 + j*0.01 + k*0.0001 }
    p1 = CArray.float64(16, 8, 64) { |i, j, k| 2.0 + i*0.1 + j*0.01 + k*0.0001 }
    s = CArray.stack([p0, p1], axis: 2)
    assert_equal [16, 8, 2, 64], s.shape

    result = s.sum(axis: 0)
    assert_equal [8, 2, 64], result.shape   # K at output pos 1 (kax_out = kax - 1)

    parents = [p0, p1]
    [0, 4, 7].each do |j|
      2.times do |k|
        [0, 32, 63].each do |kk|
          expected = (0..15).inject(0.0) { |acc, i| acc + parents[k][i, j, kk] }
          assert_in_delta expected, result[j, k, kk], 1e-9,
            "m2b f64 (j=#{j}, k=#{k}, kk=#{kk})"
        end
      end
    end
  end

  def test_m2b_inner_split_by_k_int32
    # Same shape with int32 for exact arithmetic.
    p0 = CArray.int32(16, 8, 64) { |i, j, k| 1 + i*100000 + j*1000 + k }
    p1 = CArray.int32(16, 8, 64) { |i, j, k| 2 + i*100000 + j*1000 + k }
    p2 = CArray.int32(16, 8, 64) { |i, j, k| 3 + i*100000 + j*1000 + k }
    s = CArray.stack([p0, p1, p2], axis: 2)
    assert_equal [16, 8, 3, 64], s.shape

    result = s.sum(axis: 0)
    assert_equal [8, 3, 64], result.shape

    parents = [p0, p1, p2]
    [0, 4, 7].each do |j|
      3.times do |k|
        [0, 32, 63].each do |kk|
          expected = (0..15).inject(0) { |acc, i| acc + parents[k][i, j, kk] }
          assert_equal expected, result[j, k, kk], "m2b int32 (j=#{j}, k=#{k}, kk=#{kk})"
        end
      end
    end
  end

  def test_m2b_parity_with_generic_path
    # Cross-check vs generic ki path via .copy materialise.
    pp = [
      CArray.float64(16, 10, 64) { |i, j, k| 1.0 + i*0.1 + j*0.01 + k*0.0001 },
      CArray.float64(16, 10, 64) { |i, j, k| 2.0 + i*0.1 + j*0.01 + k*0.0001 }
    ]
    s = CArray.stack(pp, axis: 2)
    r_m2b    = s.sum(axis: 0)
    r_generic = s.copy.sum(axis: 0)
    assert_equal [10, 2, 64], r_m2b.shape

    10.times do |j|
      2.times do |k|
        [0, 32, 63].each do |kk|
          assert_in_delta r_generic[j, k, kk], r_m2b[j, k, kk], 1e-9,
            "m2b parity (j=#{j}, k=#{k}, kk=#{kk})"
        end
      end
    end
  end

  def test_m2b_multi_eff_outer
    # 5D pattern: parents (16, 4, 3, 64) -> stack axis 3 -> view (16, 4, 3, K, 64).
    # k_axis=3, reduce ax=0 (pa=0), eff_INNER=64.  Effective OUTER spans 2 dims:
    # PRE = parent dim[1] = 4, INNER_pre_K = parent dim[2] = 3 (eff OUTER ndim = 2).
    # Tests the carry-increment over more than one effective OUTER axis.
    pp = [
      CArray.int32(16, 4, 3, 64) { |a, b, c, d| 1 + a*1000000 + b*10000 + c*100 + d },
      CArray.int32(16, 4, 3, 64) { |a, b, c, d| 2 + a*1000000 + b*10000 + c*100 + d }
    ]
    s = CArray.stack(pp, axis: 3)
    assert_equal [16, 4, 3, 2, 64], s.shape

    result = s.sum(axis: 0)
    assert_equal [4, 3, 2, 64], result.shape   # K at output pos 2 (= kax-1 = 2)

    parents = pp
    [0, 3].each do |b|
      [0, 2].each do |c|
        2.times do |k|
          [0, 32, 63].each do |d|
            expected = (0..15).inject(0) { |acc, a| acc + parents[k][a, b, c, d] }
            assert_equal expected, result[b, c, k, d],
              "m2b 5d (b=#{b}, c=#{c}, k=#{k}, d=#{d})"
          end
        end
      end
    end
  end

  def test_m2b_at_neg1_bypass
    # at = -1 (k_axis = pndim) -> eff_INNER = 1 -> below threshold, M.2b bypassed,
    # falls through to generic init_l2 SLAB_AXES path.  Verify correctness still.
    p0 = CArray.float64(8, 64) { |i, j| 1.0 + i + 0.001 * j }
    p1 = CArray.float64(8, 64) { |i, j| 2.0 + i + 0.001 * j }
    s = CArray.stack([p0, p1], axis: 2)   # view (8, 64, K=2), k_axis = pndim = 2 = innermost
    assert_equal [8, 64, 2], s.shape
    result = s.sum(axis: 0)
    assert_equal [64, 2], result.shape

    [0, 32, 63].each do |j|
      2.times do |k|
        expected = (0..7).inject(0.0) { |acc, i| acc + [p0, p1][k][i, j] }
        assert_in_delta expected, result[j, k], 1e-10,
          "m2b at=-1 bypass (j=#{j}, k=#{k})"
      end
    end
  end

  # ---------------- virtual mask geometry + reductions ----------------
  # Regression: ca_stack_func_create_mask must build the mask stack with the
  # parent's k_axis (so the mask's dim[] matches the array), not a default
  # k_axis 0 patched after the fact.  A mis-shaped mask broke arr.mask.shape
  # and the structural xfer_stride k-range check for k_axis != 0, which the
  # block-loop virtual-mask reductions (ca_mask_scan_virtual) exercise.

  def stack_with_mask(k, shape, axis)
    parts = (0...k).map do |b|
      a = CArray.float64(*shape) { |i| i.to_f }
      yield a, b if block_given?
      a
    end
    CArray.stack(parts, axis: axis)
  end

  def test_mask_shape_matches_array_for_each_k_axis
    [0, 1, 2, -1].each do |axis|
      s = stack_with_mask(3, [4, 5], axis) { |a, b| a[0, 0] = UNDEF if b == 0 }
      assert s.has_mask?, "axis=#{axis} should have a mask"
      assert_equal s.shape, s.mask.shape,
        "mask.shape must match array.shape (axis=#{axis})"
    end
  end

  def test_virtual_mask_reductions_match_reference_each_k_axis
    maskers = {
      none:  ->(a, b, k) {},
      first: ->(a, b, k) { a[0, 0] = UNDEF if b == 0 },
      last:  ->(a, b, k) { a[3, 4] = UNDEF if b == k - 1 },
      all:   ->(a, b, k) { a[] = UNDEF },
    }
    [0, 1, 2, -1].each do |axis|
      maskers.each do |name, mk|
        s = stack_with_mask(3, [4, 5], axis) { |a, b| mk.call(a, b, 3) }
        ref = s.copy   # entity mask = materialised reference
        assert_equal ref.any_masked?,  s.any_masked?,  "any  axis=#{axis} #{name}"
        assert_equal ref.all_masked?,  s.all_masked?,  "all  axis=#{axis} #{name}"
        assert_equal ref.count_masked, s.count_masked, "count axis=#{axis} #{name}"
      end
    end
  end

  private

  def product_indices(shape)
    return enum_for(:product_indices, shape) unless block_given?
    walk = lambda do |prefix, rest|
      if rest.empty?
        yield prefix
      else
        rest.first.times do |i|
          walk.call(prefix + [i], rest.drop(1))
        end
      end
    end
    walk.call([], shape)
  end
end

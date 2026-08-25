# frozen_string_literal: true
#
# spec_ai/test_operand_descriptor_phase1.rb
#
# S2 / PROPOSAL_OPERAND_DESCRIPTOR Phase 1 regression tests.
#
# Phase 1 replaces the per-iter inline computation
#
#   pi = STRIDE ? start + idx*step : indices[idx]
#   poff += pi * pstrides[k]
#
# with a pre-classified `ca_op_prefix_axis_t` array built once at setup:
#
#   STRIDE: poff += byte_start + idx[k] * byte_step
#   INDEX : poff += indices[idx[k]] * byte_pstride
#
# The change is algebraically equivalent (byte_start = start*pstride,
# byte_step = step*pstride).  These tests pin that equivalence holds
# across the matrix of prefix configurations that CSA + CAGrid can
# produce after D8 axis-merge (S1).
#
# Ground truth is computed by walking the parent at the view's logical
# indices in Ruby; we then compare against the engine-driven output.

require "test/unit"
require_relative "../../lib/carray"

class TestOperandDescriptorPhase1 < Test::Unit::TestCase

  def teardown
    CArray._csa_bypass = false
  end

  # ---------------------------------------------------------------
  # Per-axis ground truth: walk the parent by enumerating the view's
  # logical index per axis, then write into a row-major contig output
  # in view shape.  Independent of the engine's prefix iter.
  # ---------------------------------------------------------------

  def gather_gt_3d (parent, idx0, idx1, idx2)
    out = CArray.new(parent.data_type, [idx0.size, idx1.size, idx2.size])
    idx0.each_with_index do |i, vi|
      idx1.each_with_index do |j, vj|
        idx2.each_with_index do |k, vk|
          out[vi, vj, vk] = parent[i, j, k]
        end
      end
    end
    out
  end

  def mask_to_idx (m)
    out = []
    m.dim[0].times { |i| out << i if m[i] }
    out
  end

  def norm_inner (arg, dim)
    case arg
    when nil    then (0...dim).to_a
    when Range
      from = arg.first; from = dim + from if from < 0
      to   = arg.last;  to   = dim + to   if to < 0
      to  -= 1 if arg.exclude_end?
      (from..to).to_a
    when Integer
      i = arg; i = dim + i if i < 0
      [i]
    end
  end

  # ---------------------------------------------------------------
  # CSA: prefix is INDEX(mask) + STRIDE inner(s)
  # ---------------------------------------------------------------

  def test_prefix_index_only_after_merge
    # axes [INDEX, STRIDE(full), STRIDE(full)] -> S1 merges inner two
    # to one STRIDE; prefix becomes [INDEX] alone, slab covers merged STRIDE.
    a = CArray.int(5, 3, 4).seq
    m = CArray.boolean(5).tap { |__a| __a[] = [1, 0, 1, 1, 0] }
    v = a[m, nil, nil]
    expected = gather_gt_3d(a, mask_to_idx(m), (0...3).to_a, (0...4).to_a)
    assert_equal expected.dump_binary, v.to_ca.dump_binary
  end

  def test_prefix_index_and_partial_stride
    # axes [INDEX, STRIDE(partial,non-full)] — S1 merge won't fire on the
    # inner pair (mid not full); prefix is [INDEX, STRIDE], non-trivial
    # offset computation exercised.
    a = CArray.int(4, 5, 3).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 1, 0, 1] }
    v = a[m, nil, 0..1]
    expected = gather_gt_3d(a, mask_to_idx(m), (0...5).to_a, (0..1).to_a)
    assert_equal expected.dump_binary, v.to_ca.dump_binary
  end

  def test_prefix_with_scalar_axis
    # Scalar argument (count=1) — STRIDE axis with byte_step irrelevant.
    a = CArray.int(4, 3, 5).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    v = a[m, 1, nil]
    expected = gather_gt_3d(a, mask_to_idx(m), [1], (0...5).to_a)
    assert_equal expected.dump_binary, v.to_ca.dump_binary
  end

  def test_prefix_with_negative_range_stride_step1
    a = CArray.int(4, 3, 5).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    v = a[m, -2..-1, nil]
    expected = gather_gt_3d(a, mask_to_idx(m), [1, 2], (0...5).to_a)
    assert_equal expected.dump_binary, v.to_ca.dump_binary
  end

  # ---------------------------------------------------------------
  # Two INDEX axes (fence): prefix has two INDEX entries, no merge.
  # Exercises ca_op_prefix_axis_t[].kind == INDEX twice.
  # ---------------------------------------------------------------

  def test_prefix_two_index_axes_fenced_by_inner_stride
    a = CArray.int(4, 3, 5).seq
    m0 = CArray.boolean(4).tap { |__a| __a[] = [1, 1, 0, 1] }
    m1 = CArray.boolean(3).tap { |__a| __a[] = [1, 0, 1] }
    # Take dim-0 by mask AND dim-2 by stride; intermediate STRIDE blocks merge.
    # axes: [INDEX, STRIDE(0..2,3), STRIDE(0,5,1)] => possibly merged inner two.
    # But to test two-INDEX prefix we need a different selection path.
    # CSA's two-mask form: a[m0, m1, nil] => axes [INDEX(m0), INDEX(m1), STRIDE(full inner)]
    v = a[m0, m1, nil]
    idx0 = mask_to_idx(m0)
    idx1 = mask_to_idx(m1)
    expected = gather_gt_3d(a, idx0, idx1, (0...5).to_a)
    assert_equal expected.dump_binary, v.to_ca.dump_binary
  end

  # ---------------------------------------------------------------
  # CAGrid: all-INDEX path (Phase 1 INDEX branch exercised exclusively)
  # ---------------------------------------------------------------

  def test_cagrid_two_index_prefix
    a = CArray.int(5, 4, 3).seq
    i0 = CArray.int(3).tap { |__a| __a[] = [0, 2, 4] }
    i1 = CArray.int(2).tap { |__a| __a[] = [1, 3] }
    # Inner nil -> CAGrid produces INDEX (full range as INDEX).
    v = a.grid(i0, i1, nil)
    expected = gather_gt_3d(a, [0, 2, 4], [1, 3], (0...3).to_a)
    assert_equal expected.dump_binary, v.to_ca.dump_binary
  end

  # ---------------------------------------------------------------
  # Scatter via the same Phase 1 prefix dispatcher
  # ---------------------------------------------------------------

  def test_scatter_through_classified_prefix
    a = CArray.int(4, 3, 5).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    v = a[m, nil, nil]
    src = CArray.int(3, 3, 5).seq + 10_000
    v[] = src
    mask_to_idx(m).each_with_index do |i, vi|
      3.times do |j|
        5.times do |k|
          assert_equal src[vi, j, k], a[i, j, k],
            "scatter pre-classify mismatch at parent[#{i},#{j},#{k}]"
        end
      end
    end
  end

  # ---------------------------------------------------------------
  # fill_value via the same Phase 1 prefix dispatcher
  # ---------------------------------------------------------------

  def test_fill_value_through_classified_prefix
    a = CArray.int(4, 3, 5).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    v = a[m, nil, nil]
    v[] = 42
    mask_to_idx(m).each do |i|
      3.times do |j|
        5.times do |k|
          assert_equal 42, a[i, j, k],
            "fill pre-classify mismatch at parent[#{i},#{j},#{k}]"
        end
      end
    end
  end

  # ---------------------------------------------------------------
  # Stress: larger view to exercise the inner loop many times
  # ---------------------------------------------------------------

  def test_large_iteration_count
    # 100*1*1 = 100 prefix iters, each slab small -> Phase 1 inner
    # offset path runs many times.  No regression in correctness.
    a = CArray.int(100, 5, 6).seq
    m = CArray.boolean(100).tap { |__a| __a[] = Array.new(100) { |i| i.odd? ? 1 : 0 } }
    v = a[m, 1..3, nil]
    expected = gather_gt_3d(a, mask_to_idx(m), [1, 2, 3], (0...6).to_a)
    assert_equal expected.dump_binary, v.to_ca.dump_binary
  end

  # ---------------------------------------------------------------
  # Element width variety: pre-classify should not depend on data_type
  # ---------------------------------------------------------------

  def test_data_type_variety
    [:int8, :int16, :int32, :int64, :float32, :float64].each do |dt|
      a = CArray.send(dt, 4, 3, 5).seq
      m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
      v = a[m, 0..1, nil]
      out = CArray.new(dt, [3, 2, 5])
      mask_to_idx(m).each_with_index do |i, vi|
        (0..1).each_with_index do |j, vj|
          5.times do |k|
            out[vi, vj, k] = a[i, j, k]
          end
        end
      end
      assert_equal out.dump_binary, v.to_ca.dump_binary,
        "data_type #{dt} mismatch"
    end
  end

  # ---------------------------------------------------------------
  # Round-trip: attach! -> gather -> mutate -> scatter, both through
  # Phase 1 prefix dispatcher.  Catches any sign/offset bug.
  # ---------------------------------------------------------------

  def test_attach_round_trip
    a = CArray.float64(5, 3, 4).seq + 0.5
    m = CArray.boolean(5).tap { |__a| __a[] = [1, 0, 1, 1, 0] }
    v = a[m, nil, nil]
    v.attach! do
      v.dim[0].times do |i|
        v.dim[1].times do |j|
          v.dim[2].times do |k|
            v[i, j, k] = v[i, j, k] + 1000.0
          end
        end
      end
    end
    mask_to_idx(m).each do |i|
      3.times do |j|
        4.times do |k|
          orig = (i * 12 + j * 4 + k).to_f + 0.5
          assert_in_delta orig + 1000.0, a[i, j, k], 1e-10,
            "round-trip mismatch at parent[#{i},#{j},#{k}]"
        end
      end
    end
  end

end

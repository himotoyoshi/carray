# frozen_string_literal: true
#
# spec_ai/test_axis_dispatch_merge.rb
#
# D8 (PROPOSAL_AXIS_MERGE Phase 2) regression tests for the descriptor
# engine's in-place axis merge pass.
#
# The merge pass mutates the descriptor in place before slab detection
# and the prefix iterator run.  Correctness is asserted by comparing
# the engine-driven view operations (attach/gather, scatter, fill) to
# an independent Ruby-level ground truth that walks the parent by
# element index.
#
# Because the merge happens entirely inside the engine, these tests
# can only check end-to-end byte equivalence, not the merged ndim
# directly.  Mergeable patterns are chosen to exercise the rule:
# adjacent STRIDE axes whose effective byte strides satisfy
#   step[k] * pstride[k] == count[k+1] * step[k+1] * pstride[k+1]
# get merged into a single STRIDE axis.

require "test/unit"
require_relative "../../lib/carray"

class TestAxisDispatchMerge < Test::Unit::TestCase

  def teardown
    CArray._csa_bypass = false
  end

  # ----------------------------------------------------------------
  # Ground truth helpers
  # ----------------------------------------------------------------

  # Per-element ground truth gather for CSA view a[mask, range_or_nil, ...]
  # built by walking the parent at the selected indices.  Avoids re-using
  # any internal attach path.
  def csa_2axis_gt (parent, mask, inner_arg)
    idx0 = []
    mask.dim[0].times { |i| idx0 << i if mask[i] }
    inner = case inner_arg
            when nil then (0...parent.dim[1]).to_a
            when Range
              from = inner_arg.first
              from = parent.dim[1] + from if from < 0
              to   = inner_arg.last
              to   = parent.dim[1] + to   if to < 0
              to  -= 1 if inner_arg.exclude_end?
              (from..to).to_a
            when Integer
              i = inner_arg
              i = parent.dim[1] + i if i < 0
              [i]
            end
    out = CArray.new(parent.data_type, [idx0.size, inner.size])
    idx0.each_with_index do |i, vi|
      inner.each_with_index do |j, vj|
        out[vi, vj] = parent[i, j]
      end
    end
    out
  end

  def csa_3axis_gt (parent, mask, arg1, arg2)
    idx0 = []
    mask.dim[0].times { |i| idx0 << i if mask[i] }
    norm = ->(arg, dim) {
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
    }
    i1 = norm.call(arg1, parent.dim[1])
    i2 = norm.call(arg2, parent.dim[2])
    out = CArray.new(parent.data_type, [idx0.size, i1.size, i2.size])
    idx0.each_with_index do |i, vi|
      i1.each_with_index do |j, vj|
        i2.each_with_index do |k, vk|
          out[vi, vj, vk] = parent[i, j, k]
        end
      end
    end
    out
  end

  # ----------------------------------------------------------------
  # CSA gather: mergeable patterns (post-INDEX two STRIDE axes merge)
  # ----------------------------------------------------------------

  def test_csa_3d_inner_two_stride_axes_mergeable_full
    # axes = [INDEX(mask), STRIDE(0,3,1), STRIDE(0,5,1)]
    # ebs_1 = 1 * (5*4) = 20; need 5*ebs_2 = 5*4 = 20 -> mergeable
    a = CArray.int(4, 3, 5).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    v = a[m, nil, nil]
    assert_equal CASelectAxis, v.class
    assert_equal csa_3axis_gt(a, m, nil, nil).dump_binary,
                 v.to_ca.dump_binary
  end

  def test_csa_3d_inner_two_stride_partial_inner_full_outer
    # axes = [INDEX, STRIDE(0,2,1)|partial, STRIDE(0,5,1)|full]
    # ebs_1 = 20; 5*ebs_2 = 20 -> still mergeable
    a = CArray.int(4, 3, 5).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    v = a[m, 0..1, nil]
    assert_equal csa_3axis_gt(a, m, 0..1, nil).dump_binary,
                 v.to_ca.dump_binary
  end

  def test_csa_3d_inner_two_stride_full_inner_partial_outer
    # axes = [INDEX, STRIDE(0,3,1), STRIDE(0,3,1)]
    # ebs_1 = 20; 3*ebs_2 = 12 -> NOT mergeable (count[k+1]*ebs[k+1] != ebs[k])
    a = CArray.int(4, 3, 5).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    v = a[m, nil, 0..2]
    assert_equal csa_3axis_gt(a, m, nil, 0..2).dump_binary,
                 v.to_ca.dump_binary
  end

  def test_csa_3d_inner_scalar_then_full
    # Scalar axis -> count=1; STRIDE inner full.
    # axes = [INDEX, STRIDE(start=1,count=1,step=1), STRIDE(0,5,1)]
    # ebs_1 = 1*20 = 20; 5*4 = 20 -> mergeable.  start update:
    # new_start = 1*5 + 0 = 5, count=5, step=1, pstride=4
    a = CArray.int(4, 3, 5).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    v = a[m, 1, nil]
    assert_equal csa_3axis_gt(a, m, 1, nil).dump_binary,
                 v.to_ca.dump_binary
  end

  def test_csa_3d_negative_range
    a = CArray.int(4, 3, 5).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    v = a[m, -2..-1, nil]
    assert_equal csa_3axis_gt(a, m, -2..-1, nil).dump_binary,
                 v.to_ca.dump_binary
  end

  def test_csa_4d_three_stride_axes_chain_merge
    # Parent (3,2,4,5).  axes = [INDEX, STRIDE(0,2,1), STRIDE(0,4,1), STRIDE(0,5,1)]
    # Innermost merge (axes 2,3): ebs_2 = 1*20=20; 5*4=20 -> merge to STRIDE(0,20,1) pstride=4
    # Next pass (axes 1, merged): ebs_1 = 1*(4*5*4)=80; 20*4=80 -> merge to STRIDE(0,40,1) pstride=4
    # Final: ndim 2 with [INDEX, STRIDE]
    a = CArray.int(3, 2, 4, 5).seq
    m = CArray.boolean(3).tap { |__a| __a[] = [1, 0, 1] }
    v = a[m, nil, nil, nil]
    # Build 4D ground truth manually
    idx0 = []
    m.dim[0].times { |i| idx0 << i if m[i] }
    expected = CArray.int(idx0.size, 2, 4, 5)
    idx0.each_with_index do |i, vi|
      2.times do |j|
        4.times do |k|
          5.times do |l|
            expected[vi, j, k, l] = a[i, j, k, l]
          end
        end
      end
    end
    assert_equal expected.dump_binary, v.to_ca.dump_binary
  end

  # ----------------------------------------------------------------
  # INDEX fence: merge must not cross an INDEX axis
  # ----------------------------------------------------------------

  def test_csa_3d_two_masks_index_fence
    # axes = [INDEX(m0), STRIDE(0,4,1), INDEX(m2)]
    # Adjacent (0,1): kinds differ -> no merge.
    # Adjacent (1,2): kinds differ -> no merge.
    # ndim stays 3.
    a = CArray.int(3, 4, 5).seq
    m0 = CArray.boolean(3).tap { |__a| __a[] = [1, 0, 1] }
    m2 = CArray.boolean(5).tap { |__a| __a[] = [0, 1, 0, 1, 1] }
    v = a[m0, nil, m2]
    # Ground truth
    idx0 = []; m0.dim[0].times { |i| idx0 << i if m0[i] }
    idx2 = []; m2.dim[0].times { |i| idx2 << i if m2[i] }
    expected = CArray.int(idx0.size, 4, idx2.size)
    idx0.each_with_index do |i, vi|
      4.times do |j|
        idx2.each_with_index do |k, vk|
          expected[vi, j, vk] = a[i, j, k]
        end
      end
    end
    assert_equal expected.dump_binary, v.to_ca.dump_binary
  end

  # ----------------------------------------------------------------
  # scatter (D5) under merge: writes must hit the same parent cells
  # ----------------------------------------------------------------

  def test_csa_scatter_through_mergeable_axes
    a = CArray.int(4, 3, 5).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    v = a[m, nil, nil]
    # Overwrite the view with a known pattern via sync_data (= scatter).
    src = CArray.int(3, 3, 5).seq + 1000
    v[] = src
    # Verify every selected parent cell received the right value.
    idx0 = []; m.dim[0].times { |i| idx0 << i if m[i] }
    idx0.each_with_index do |i, vi|
      3.times do |j|
        5.times do |k|
          assert_equal src[vi, j, k], a[i, j, k],
            "scatter mismatch at parent[#{i},#{j},#{k}]"
        end
      end
    end
    # Non-selected rows must be unchanged
    skipped = (0...4).to_a - idx0
    skipped.each do |i|
      3.times do |j|
        5.times do |k|
          # Original seq value at (i,j,k) = i*15 + j*5 + k
          assert_equal i*15 + j*5 + k, a[i, j, k],
            "non-selected parent[#{i},#{j},#{k}] should be untouched"
        end
      end
    end
  end

  # ----------------------------------------------------------------
  # fill_value (D6) under merge
  # ----------------------------------------------------------------

  def test_csa_fill_value_through_mergeable_axes
    a = CArray.int(4, 3, 5).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    v = a[m, nil, nil]
    v[] = -7
    idx0 = []; m.dim[0].times { |i| idx0 << i if m[i] }
    idx0.each_with_index do |i, _vi|
      3.times do |j|
        5.times do |k|
          assert_equal(-7, a[i, j, k],
            "fill mismatch at parent[#{i},#{j},#{k}]")
        end
      end
    end
    # Non-selected untouched
    skipped = (0...4).to_a - idx0
    skipped.each do |i|
      3.times do |j|
        5.times do |k|
          assert_equal i*15 + j*5 + k, a[i, j, k],
            "non-selected parent[#{i},#{j},#{k}] should be untouched"
        end
      end
    end
  end

  # ----------------------------------------------------------------
  # Round-trip via attach! (gather + scatter through the merged engine)
  # ----------------------------------------------------------------

  def test_csa_attach_bang_round_trip_through_mergeable_axes
    a = CArray.int(4, 3, 5).seq
    m = CArray.boolean(4).tap { |__a| __a[] = [1, 0, 1, 1] }
    v = a[m, nil, nil]
    # attach -> mutate -> sync; both gather and scatter go through merge.
    v.attach! do
      shape = v.dim
      shape[0].times do |i|
        shape[1].times do |j|
          shape[2].times do |k|
            v[i, j, k] = v[i, j, k] * 2 + 1
          end
        end
      end
    end
    idx0 = []; m.dim[0].times { |i| idx0 << i if m[i] }
    idx0.each_with_index do |i, _vi|
      3.times do |j|
        5.times do |k|
          orig = i*15 + j*5 + k
          assert_equal orig*2 + 1, a[i, j, k],
            "round-trip mismatch at parent[#{i},#{j},#{k}]"
        end
      end
    end
  end

  # ----------------------------------------------------------------
  # Single-axis edge: merge cannot reduce ndim below 1
  # ----------------------------------------------------------------

  def test_csa_1d_single_index_axis_no_op
    a = CArray.int(5).seq
    m = CArray.boolean(5).tap { |__a| __a[] = [1, 0, 1, 0, 1] }
    v = a[m]
    expected = CArray.int(3).tap { |__a| __a[] = [0, 2, 4] }
    assert_equal expected.dump_binary, v.to_ca.dump_binary
  end

  # ----------------------------------------------------------------
  # CAGrid path (all-INDEX after Range->INDEX): merge rule never fires,
  # engine output must still match ground truth.
  # ----------------------------------------------------------------

  def test_cagrid_3d_all_index_no_merge
    a = CArray.int(4, 3, 5).seq
    i0 = CArray.int(3).tap { |__a| __a[] = [0, 2, 3] }
    i1 = CArray.int(2).tap { |__a| __a[] = [0, 1] }
    v = a.grid(i0, i1, nil)
    # Ground truth
    idx0 = [0, 2, 3]; idx1 = [0, 1]; idx2 = (0...5).to_a
    expected = CArray.int(idx0.size, idx1.size, idx2.size)
    idx0.each_with_index do |i, vi|
      idx1.each_with_index do |j, vj|
        idx2.each_with_index do |k, vk|
          expected[vi, vj, vk] = a[i, j, k]
        end
      end
    end
    assert_equal expected.dump_binary, v.to_ca.dump_binary
  end

end

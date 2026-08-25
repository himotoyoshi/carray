# CAStack × CATranspose chain — comprehensive correctness pin
#
# Verifies that CATranspose(CAStack) and its permutations behave correctly
# across:
#   - copy materialise (= post c3b2833 force-materialise)
#   - element access at [i, j, k]
#   - reductions on each axis (including the K-axis after permutation)
#   - multi-axis reductions
#   - reductions through CATranspose(CAStack) where K stays innermost vs
#     outer vs middle
#   - chains with element-wise binop
#
# Ground truth: `view.copy` (3.0 semantics) builds a fresh entity that
# routes through the standard CA_OBJ_ARRAY reduce path (L.7 Tier 1 +
# eager); compare CAStack-rooted view path against entity path.

require 'test/unit'
require 'carray'

class TestCAStackTransposeChain < Test::Unit::TestCase

  REDUCTIONS = %i[sum mean min max prod variance stddev]

  # ---- helpers ----

  def build_stack(k, *shape)
    list = Array.new(k) { |kk|
      CArray.float64(*shape) { |i| Math.sin(kk * 0.31 + i * 0.13) }
    }
    [CArray.stack(list), list]
  end

  def assert_copy_parity(view, label)
    # `.copy` is the post-3.0 materialise primitive; the result must equal
    # a per-cell readback through view[..] (= ground truth independent of
    # kernel_iterator's path).
    eager = view.copy
    # iterate every index and compare scalar-by-scalar (slow but cleanest
    # cross-path check, fine for the small shapes in this suite)
    shape = view.shape
    idx_each(shape) do |idx|
      vv = view[*idx]
      ee = eager[*idx]
      assert_in_delta vv, ee, 1e-12,
                      "#{label} idx=#{idx.inspect}: view=#{vv} eager=#{ee}"
    end
  end

  def assert_reduction_parity(view, label)
    eager = view.copy
    (0...view.ndim).each do |ax|
      REDUCTIONS.each do |op|
        a = view.send(op, axis: ax)
        b = eager.send(op, axis: ax)
        d = (a.copy - b.copy).abs.max
        assert d < 1e-9,
               "#{label} #{op} axis:#{ax}: maxdiff=#{d}"
      end
    end
  end

  def assert_multi_axis_reduction_parity(view, axes_list, label)
    eager = view.copy
    axes_list.each do |axes|
      %i[sum mean].each do |op|
        a = view.send(op, axis: axes)
        b = eager.send(op, axis: axes)
        # reducing all axes collapses to a scalar (Float) — compare directly;
        # otherwise compare via materialised diff.
        if a.is_a?(Float) || b.is_a?(Float)
          assert_in_delta a.to_f, b.to_f, 1e-9,
                          "#{label} #{op} axes:#{axes.inspect}"
        else
          d = (a.copy - b.copy).abs.max
          assert d < 1e-9,
                 "#{label} #{op} axes:#{axes.inspect}: maxdiff=#{d}"
        end
      end
    end
  end

  def idx_each(shape, &block)
    if shape.length == 1
      shape[0].times { |i| yield [i] }
    elsif shape.length == 2
      shape[0].times { |i| shape[1].times { |j| yield [i, j] } }
    elsif shape.length == 3
      shape[0].times { |i| shape[1].times { |j| shape[2].times { |k| yield [i, j, k] } } }
    else
      raise "shape rank > 3 not supported in test helper"
    end
  end

  # ---- direct stack baseline (= no transpose, sanity floor) ----

  def test_stack_no_transpose_copy
    view, = build_stack(5, 4, 6)   # (5, 4, 6)
    assert_copy_parity(view, "stack-only")
    assert_reduction_parity(view, "stack-only")
  end

  # ---- CATranspose × CAStack: K-axis stays first ----

  def test_transpose_parent_axes_only
    # (K, H, W) -> (K, W, H): K stays axis 0, parent axes swap
    view, = build_stack(5, 4, 6)
    t = view.transpose(0, 2, 1)
    assert_equal [5, 6, 4], t.shape
    assert_copy_parity(t, "T(stack)[0,2,1]")
    assert_reduction_parity(t, "T(stack)[0,2,1]")
  end

  # ---- CATranspose × CAStack: K-axis moved to middle ----

  def test_transpose_K_to_middle
    # (K, H, W) -> (H, K, W): K becomes axis 1
    view, = build_stack(5, 4, 6)
    t = view.transpose(1, 0, 2)
    assert_equal [4, 5, 6], t.shape
    assert_copy_parity(t, "T(stack)[1,0,2]")
    assert_reduction_parity(t, "T(stack)[1,0,2]")
  end

  # ---- CATranspose × CAStack: K-axis moved to innermost ----

  def test_transpose_K_to_innermost
    # (K, H, W) -> (H, W, K): K becomes axis 2 (innermost)
    view, = build_stack(5, 4, 6)
    t = view.transpose(1, 2, 0)
    assert_equal [4, 6, 5], t.shape
    assert_copy_parity(t, "T(stack)[1,2,0]")
    assert_reduction_parity(t, "T(stack)[1,2,0]")
  end

  # ---- CATranspose × CAStack: full reverse ----

  def test_transpose_reverse
    # (K, H, W) -> (W, H, K)
    view, = build_stack(5, 4, 6)
    t = view.transpose(2, 1, 0)
    assert_equal [6, 4, 5], t.shape
    assert_copy_parity(t, "T(stack)[2,1,0]")
    assert_reduction_parity(t, "T(stack)[2,1,0]")
  end

  # ---- K-axis reduction identity: reduce K on the original stack and on each transpose ----

  def test_K_axis_reduction_identity_across_permutations
    # Whichever axis K lands on after permutation, reducing along that
    # axis must produce the same answer (up to a shape transform).
    view, list = build_stack(7, 5, 3)

    # canonical: K reduce on original
    canonical = view.mean(axis: 0).copy   # shape (5, 3)
    assert_equal [5, 3], canonical.shape

    # transpose(0, 2, 1): K still axis 0; result shape (3, 5) (= transposed)
    t1 = view.transpose(0, 2, 1)
    r1 = t1.mean(axis: 0)
    assert_equal [3, 5], r1.shape
    # element-wise equality vs canonical with axes swapped
    canonical.shape[0].times do |i|
      canonical.shape[1].times do |j|
        assert_in_delta canonical[i, j], r1[j, i], 1e-12,
                        "[0,2,1] K-reduce idx=#{i},#{j}"
      end
    end

    # transpose(1, 0, 2): K is axis 1; reducing axis:1 should give canonical shape (5, 3)
    t2 = view.transpose(1, 0, 2)
    r2 = t2.mean(axis: 1)
    assert_equal [5, 3], r2.shape
    canonical.shape[0].times do |i|
      canonical.shape[1].times do |j|
        assert_in_delta canonical[i, j], r2[i, j], 1e-12,
                        "[1,0,2] K-axis=1 reduce idx=#{i},#{j}"
      end
    end

    # transpose(1, 2, 0): K is axis 2 (innermost); reducing axis:2 should give canonical (5, 3)
    t3 = view.transpose(1, 2, 0)
    r3 = t3.mean(axis: 2)
    assert_equal [5, 3], r3.shape
    canonical.shape[0].times do |i|
      canonical.shape[1].times do |j|
        assert_in_delta canonical[i, j], r3[i, j], 1e-12,
                        "[1,2,0] K-axis=2 reduce idx=#{i},#{j}"
      end
    end
  end

  # ---- multi-axis reductions across permutations ----

  def test_multi_axis_reductions
    view, = build_stack(4, 5, 3)
    [view,
     view.transpose(0, 2, 1),
     view.transpose(1, 0, 2),
     view.transpose(2, 1, 0)].each do |v|
      label = "shape=#{v.shape.inspect}"
      assert_multi_axis_reduction_parity(v, [[0, 1], [1, 2], [0, 2], [0, 1, 2]], label)
    end
  end

  # ---- chain with element-wise binop ----

  def test_transposed_stack_arithmetic
    view, = build_stack(5, 4, 6)
    t = view.transpose(1, 0, 2)             # (4, 5, 6)
    chained = (t * 2.0 + 1.0).copy           # materialise eager-equiv
    # reference
    ref = t.copy
    ref.shape[0].times do |i|
      ref.shape[1].times do |j|
        ref.shape[2].times do |k|
          ref[i, j, k] = ref[i, j, k] * 2.0 + 1.0
        end
      end
    end
    d = (chained - ref).abs.max
    assert d < 1e-12, "transpose+lazy arithmetic maxdiff=#{d}"
  end

  # ---- larger K with masked source: must take SRC_ATTACH fallback ----

  def test_masked_stack_transpose
    a = CArray.float64(4, 6) { |i, j| i * 10 + j }
    a[0, 0] = UNDEF
    b = CArray.float64(4, 6) { |i, j| 100 + i * 10 + j }
    c = CArray.float64(4, 6) { |i, j| 200 + i * 10 + j }
    view = CArray.stack([a, b, c])           # K=3 with mask
    t = view.transpose(1, 0, 2)              # (4, 3, 6)
    eager = view.copy
    eager_t = eager.transpose(1, 0, 2).copy
    # reductions handle mask correctly through the fallback
    %i[sum mean].each do |op|
      d = (t.send(op, axis: 1).copy - eager_t.send(op, axis: 1).copy).abs.max
      assert d < 1e-9, "masked T(stack) #{op} axis:1 maxdiff=#{d}"
    end
  end

  # ---- to_ca / copy semantic (= 3.0 split, c3b2833 landed) ----
  #
  # 3.0 split (c3b2833): to_ca returns self for a data view (CAStack and its
  # CATranspose chain are data views, not lazy), copy always owns a fresh
  # independent entity.  (Was aliased to copy in 2.x; flipped on merge of the
  # split into this line.)

  def test_to_ca_is_self_copy_is_fresh
    view, = build_stack(3, 4, 5)
    assert_equal view.object_id, view.to_ca.object_id,
                 "CAStack#to_ca returns self for a data view (3.0, c3b2833)"
    refute_equal view.object_id, view.copy.object_id,
                 "CAStack#copy must always be a fresh entity"
  end

  def test_copy_materialise_is_independent
    view, = build_stack(3, 4, 5)
    copy = view.copy
    # mutating the entity does not affect the view's underlying parents
    copy[0, 0, 0] = 999.0
    refute_equal 999.0, view[0, 0, 0],
                 "copy must produce an independent buffer"
  end
end

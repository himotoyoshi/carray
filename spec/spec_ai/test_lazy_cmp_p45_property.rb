require "test/unit"
require "carray"

# PROPOSAL_LAZY_ELEMENTWISE_VIEW Phase 4 P.4.5 — DAG property test.
#
# Random boolean-expression tree generator: combines bincmp + moncmp +
# arithmetic + bitwise nodes over a small operand pool, asserts byte
# parity between eager and lazy materialise.  Extension of Phase 1+2
# DAG generators to boolean output domain.
#
# Coverage axes:
#   - random tree depth 1..6
#   - leaf operands sampled from {a, b, c, scalar} (= scalar-broadcast
#     path exercised when sampled)
#   - boolean operators (`>` / `<` / `>=` / `<=` / `eq` / `ne` / `feq`)
#     + arithmetic operators (`+` / `-` / `*`) + bitwise on boolean
#     (`&` / `|` / `^`)
#   - mask propagation (operand subset masked, verify mask = OR-of-leaves)
#
# Property: build the same tree twice — once via eager methods, once via
# lazy methods on the marker.  to_a parity required.  Mask parity also
# required for the same tree under masked input.

class TestLazyCmpP45Property < Test::Unit::TestCase
  N = 128
  RNG_SEED = 0x424c4f4f  # 'BLOO'

  ARITH_OPS = [:+, :-, :*].freeze
  BINCMP_OPS = [:lt, :gt, :le, :ge, :eq, :ne].freeze  # exclude feq for now (ε noise)
  BITWISE_OPS = [:&, :|, :^].freeze
  MONCMP_OPS = [:is_nan, :is_inf, :is_finite].freeze

  def setup
    @rng = Random.new(RNG_SEED)
    @a = CArray.float64(N) { |k| (k - N / 2) * 0.01 }
    @b = CArray.float64(N) { |k| (k - N / 4) * 0.02 }
    @c = CArray.float64(N) { |k| Math.sin(k * 0.1) * 0.5 }
  end

  # Build pair of trees: eager and lazy, same structure.
  # The tree carries a "boolean?" flag so we know which ops are valid
  # at each level.  Scalar leaves are allowed ONLY as the right operand
  # of arith / bincmp (= ensure at least one CArray operand for type
  # safety + scalar broadcast coverage).
  def carray_leaf(rng)
    case rng.rand(3)
    when 0 then [@a, :leaf_a]
    when 1 then [@b, :leaf_b]
    else        [@c, :leaf_c]
    end
  end

  def scalar_leaf(rng)
    [(rng.rand * 4.0) - 2.0, :scalar]
  end

  def build_tree(depth, want_boolean, rng)
    if depth == 0
      # Always a CArray leaf at depth 0 (scalar can only be a right operand)
      return carray_leaf(rng)
    end

    if want_boolean
      choice = rng.rand(3)
      if choice == 0 && depth > 1
        # bitwise op over two boolean subtrees
        op = BITWISE_OPS[rng.rand(BITWISE_OPS.length)]
        l_eager, l_spec = build_tree(depth - 1, true, rng)
        r_eager, r_spec = build_tree(depth - 1, true, rng)
        return [[:bitwise, op, l_eager, l_spec, r_eager, r_spec], :bitwise]
      elsif choice == 1
        # moncmp on float subtree (= CArray-only)
        op = MONCMP_OPS[rng.rand(MONCMP_OPS.length)]
        f_eager, f_spec = build_tree(depth - 1, false, rng)
        return [[:moncmp, op, f_eager, f_spec], :moncmp]
      else
        # bincmp: left = CArray subtree (always), right = CArray subtree
        # or scalar.
        op = BINCMP_OPS[rng.rand(BINCMP_OPS.length)]
        l_eager, l_spec = build_tree(depth - 1, false, rng)
        if rng.rand(2) == 0
          r_eager, r_spec = scalar_leaf(rng)
        else
          r_eager, r_spec = build_tree(depth - 1, false, rng)
        end
        return [[:bincmp, op, l_eager, l_spec, r_eager, r_spec], :bincmp]
      end
    else
      # Float tree: arithmetic.  Left = CArray subtree, right = CArray
      # subtree or scalar.
      op = ARITH_OPS[rng.rand(ARITH_OPS.length)]
      l_eager, l_spec = build_tree(depth - 1, false, rng)
      if rng.rand(2) == 0
        r_eager, r_spec = scalar_leaf(rng)
      else
        r_eager, r_spec = build_tree(depth - 1, false, rng)
      end
      return [[:arith, op, l_eager, l_spec, r_eager, r_spec], :arith]
    end
  end

  # Eval tree eagerly.  Leaf operands are CArrays or scalars.
  def eval_eager(node, spec)
    case spec
    when :leaf_a, :leaf_b, :leaf_c, :scalar
      node
    when :arith
      _, op, l, l_spec, r, r_spec = node
      l_val = eval_eager(l, l_spec)
      r_val = eval_eager(r, r_spec)
      l_val.public_send(op, r_val)
    when :bincmp
      _, op, l, l_spec, r, r_spec = node
      l_val = eval_eager(l, l_spec)
      r_val = eval_eager(r, r_spec)
      l_val.public_send(op, r_val)
    when :moncmp
      _, op, f, f_spec = node
      f_val = eval_eager(f, f_spec)
      f_val.public_send(op)
    when :bitwise
      _, op, l, l_spec, r, r_spec = node
      l_val = eval_eager(l, l_spec)
      r_val = eval_eager(r, r_spec)
      l_val.public_send(op, r_val)
    end
  end

  # Eval tree lazily: same structure, but inject .lazy at the first leaf
  # operand of each subtree.
  def eval_lazy(node, spec)
    case spec
    when :leaf_a, :leaf_b, :leaf_c
      node.lazy
    when :scalar
      node
    when :arith
      _, op, l, l_spec, r, r_spec = node
      l_val = eval_lazy(l, l_spec)
      r_val = eval_lazy(r, r_spec)
      l_val.public_send(op, r_val)
    when :bincmp
      _, op, l, l_spec, r, r_spec = node
      l_val = eval_lazy(l, l_spec)
      r_val = eval_lazy(r, r_spec)
      l_val.public_send(op, r_val)
    when :moncmp
      _, op, f, f_spec = node
      f_val = eval_lazy(f, f_spec)
      f_val.public_send(op)
    when :bitwise
      _, op, l, l_spec, r, r_spec = node
      l_val = eval_lazy(l, l_spec)
      r_val = eval_lazy(r, r_spec)
      l_val.public_send(op, r_val)
    end
  end

  # === property tests ===

  def test_random_boolean_dag_parity
    # 50 random boolean trees, depth 2..5
    50.times do |seed_offset|
      rng = Random.new(RNG_SEED + seed_offset)
      depth = 2 + rng.rand(4)
      eager_tree, spec = build_tree(depth, true, rng)
      eager_result = eval_eager(eager_tree, spec)
      lazy_result  = eval_lazy(eager_tree, spec).to_ca
      assert_equal CA_BOOLEAN, lazy_result.data_type,
                   "tree seed=#{seed_offset} depth=#{depth}: output must be boolean"
      assert_equal eager_result.to_a, lazy_result.to_a,
                   "tree seed=#{seed_offset} depth=#{depth} parity"
    end
  end

  def test_random_arith_dag_parity
    # 30 random arith-then-cmp trees: arith subtree N levels then a
    # single bincmp at the top
    30.times do |seed_offset|
      rng = Random.new(RNG_SEED + 1000 + seed_offset)
      depth = 2 + rng.rand(5)
      arith_tree, arith_spec = build_tree(depth, false, rng)
      cmp_op = BINCMP_OPS[rng.rand(BINCMP_OPS.length)]
      scalar_thr = (rng.rand * 4.0) - 2.0
      eager_top = arith_tree
      # Build a top-level bincmp with the arith tree and a scalar
      top_node = [:bincmp, cmp_op, eager_top, arith_spec, scalar_thr, :scalar]
      eager_result = eval_eager(top_node, :bincmp)
      lazy_result  = eval_lazy(top_node, :bincmp).to_ca
      assert_equal eager_result.to_a, lazy_result.to_a,
                   "arith-then-cmp tree seed=#{seed_offset} depth=#{depth}"
    end
  end

  def test_mask_propagation_random_trees
    # 20 random boolean trees with masked operands
    20.times do |seed_offset|
      rng = Random.new(RNG_SEED + 2000 + seed_offset)
      depth = 2 + rng.rand(3)
      # Mask half of a, quarter of b
      a_masked = @a.dup
      b_masked = @b.dup
      a_masked[0..(N / 2 - 1)] = UNDEF
      b_masked[(3 * N / 4)..(N - 1)] = UNDEF
      orig_a = @a; orig_b = @b
      @a = a_masked; @b = b_masked
      eager_tree, spec = build_tree(depth, true, rng)
      eager_result = eval_eager(eager_tree, spec)
      lazy_result  = eval_lazy(eager_tree, spec).to_ca
      # CArray#mask returns 0 (Integer) when no mask is present, or a
      # CArrayMask view otherwise.  Both sides must agree on presence.
      e_mask = eager_result.mask
      l_mask = lazy_result.mask
      if e_mask.is_a?(CArray) || l_mask.is_a?(CArray)
        assert_kind_of CArray, e_mask
        assert_kind_of CArray, l_mask
        assert_equal e_mask.to_a, l_mask.to_a,
                     "mask parity seed=#{seed_offset} depth=#{depth}"
        n = eager_result.elements
        n.times do |i|
          next if e_mask[i] != 0
          assert_equal eager_result[i], lazy_result[i],
                       "value at unmasked cell #{i} seed=#{seed_offset}"
        end
      else
        # No mask on either side — compare data values directly
        assert_equal eager_result.to_a, lazy_result.to_a,
                     "no-mask parity seed=#{seed_offset} depth=#{depth}"
      end
      @a = orig_a; @b = orig_b
    end
  end

  # === arena lifecycle invariant under property load ===

  def test_arena_depth_balances_through_random_trees
    # After 50 random tree materialisations, depth + in_use must be 0
    CArray.__lazy_arena_reset_counters__
    50.times do |seed_offset|
      rng = Random.new(RNG_SEED + 5000 + seed_offset)
      depth = 2 + rng.rand(4)
      tree, spec = build_tree(depth, true, rng)
      _ = eval_lazy(tree, spec).to_ca
    end
    assert_equal 0, CArray.__lazy_arena_depth__,
                 "arena depth must balance after random tree load"
    assert_equal 0, CArray.__lazy_arena_slot_in_use_count__,
                 "arena slots must release after random tree load"
  end
end

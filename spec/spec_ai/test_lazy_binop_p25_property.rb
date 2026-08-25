# PROPOSAL_LAZY_ELEMENTWISE_VIEW Phase 2 (P.2.5) — DAG property test.
#
# Random expression-tree generator over a fixed set of monop + binop
# operators with shared-subexpression rate = 30% (= DAG, not tree).
# Run 100 seeds and assert lazy materialise byte-parity vs eager.

$LOAD_PATH.unshift File.expand_path("../../ext", __dir__)
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "carray"
require "test/unit"

# Simple op-set chosen so the eager / lazy paths share the same
# numeric behaviour for f64 leaves (= no overflow, no NaN-producing
# ops on negative input).  Domain validity is the test author's
# responsibility — we keep operands positive everywhere.
MONOP_OPS = %i[sqrt sin cos exp neg].freeze
BINOP_OPS = %i[+ - * /].freeze

# Build a random expression tree of given depth, choosing operands
# from `leaves`.  At leaf nodes the tree returns a Symbol :leafK so
# we can reuse the same leaf across multiple sites (= shared sub-
# expression, the "DAG" property).
def build_tree(rng, depth, leaves_count, share_rate: 0.3)
  if depth == 0 || rng.rand < 0.2
    [:leaf, rng.rand(leaves_count)]
  elsif rng.rand < 0.4
    op = MONOP_OPS.sample(random: rng)
    [:monop, op, build_tree(rng, depth - 1, leaves_count, share_rate: share_rate)]
  else
    op = BINOP_OPS.sample(random: rng)
    left  = build_tree(rng, depth - 1, leaves_count, share_rate: share_rate)
    # Share with the left subtree some of the time.
    right = if rng.rand < share_rate
              left
            else
              build_tree(rng, depth - 1, leaves_count, share_rate: share_rate)
            end
    [:binop, op, left, right]
  end
end

# Walk the tree using `recv_factory.call(leaf_index)` to build each
# leaf and apply the recorded ops.  Used for both lazy and eager
# evaluation by swapping the leaf factory.
def eval_tree(tree, recv_factory)
  case tree[0]
  when :leaf
    recv_factory.call(tree[1])
  when :monop
    inner = eval_tree(tree[2], recv_factory)
    inner.send(tree[1])
  when :binop
    l = eval_tree(tree[2], recv_factory)
    r = eval_tree(tree[3], recv_factory)
    l.send(tree[1], r)
  end
end

class TestLazyBinopP25Property < Test::Unit::TestCase

  def test_random_dag_parity_100_seeds
    n_leaves = 4
    n_seeds  = 100
    failed = []

    n_seeds.times do |seed|
      rng = Random.new(seed)
      depth = 1 + rng.rand(4)   # depth 1..4
      tree  = build_tree(rng, depth, n_leaves)

      # Build f64 leaves with positive seq + offset so domain ops
      # (sqrt, log if used) and divisions stay finite.
      leaves = n_leaves.times.map do |i|
        CArray.float64(32).seq + 1.0 + i
      end
      eager_factory = ->(k) { leaves[k] }
      # For lazy, the FIRST leaf access wraps the entity in `.lazy`
      # so the dispatcher routes into CAMonOp/CABinOp.  Subsequent
      # leaf accesses can return the entity directly (= leaf in
      # eager form, used as RHS of a binop with lazy LHS).
      lazy_factory = ->(k) { k == 0 ? leaves[k].lazy : leaves[k] }

      eager_result = eval_tree(tree, eager_factory)
      lazy_result  = eval_tree(tree, lazy_factory)
      # Materialise lazy if it's still a view.
      lazy_materialised = lazy_result.is_a?(CArray) && !lazy_result.is_a?(Numeric) \
        ? lazy_result.to_ca \
        : lazy_result

      # eager_result may be a CArray or a Numeric (= for tree of
      # depth 0, but we forced depth>=1, so always CArray).
      eq = if eager_result.respond_to?(:dump_binary)
             eager_result.dump_binary == lazy_materialised.dump_binary
           else
             eager_result == lazy_materialised
           end
      failed << [seed, tree] unless eq
    end

    if failed.any?
      flunk "DAG parity failed at #{failed.size}/#{n_seeds} seeds: " \
            "first failure seed=#{failed.first[0]} tree=#{failed.first[1].inspect}"
    end
    assert true, "100 random DAG seeds parity ✓"
  end

  # ---------------------------------------- mid-chain cast regression --

  def test_mid_chain_cast_binop_phase1_finding_extended
    # Phase 1 finding #1: preserve monop before widening monop on an
    # integer parent puts a CAMonOp(:cast) node mid-chain.  Phase 2
    # extends this to binop: either operand can carry a mid-chain
    # cast.  Regression: lazy parity vs eager must hold.
    [:int8, :int16, :int32].each do |dt|
      ai = CArray.send(dt, 16).seq + 1
      af = CArray.float64(16).seq + 0.25
      # Left: preserve monop (:neg) then widening (:sqrt) → mid-chain
      # cast_f64 inserted between neg and sqrt.
      v = ai.lazy.neg.sqrt + af
      e = ai.neg.sqrt + af
      assert_equal e.dump_binary, v.to_ca.dump_binary, "lhs #{dt}"
      # Right: same pattern on RHS.
      v = af + ai.lazy.neg.sqrt
      e = af + ai.neg.sqrt
      assert_equal e.dump_binary, v.to_ca.dump_binary, "rhs #{dt}"
    end
  end

  # ---------------------------------------- shared subexpr smoke --

  def test_shared_subexpression_evaluates_correctly
    # `(a.lazy + b) * (a.lazy + b)` — the left subtree appears twice.
    # We don't yet share the materialisation (= each occurrence
    # builds its own CABinOp), but the numeric result must be
    # correct.  This is a smoke for the eventual Phase 3 arena pool
    # which CAN share.
    a = CArray.float64(32).seq + 1.0
    b = CArray.float64(32).seq + 2.0
    sub = (a.lazy + b)
    v = sub * sub  # shared
    e_sub = a + b
    e = e_sub * e_sub
    assert_equal e.dump_binary, v.to_ca.dump_binary
  end
end

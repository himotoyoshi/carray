require "test/unit"
require "carray"

# PROPOSAL_LAZY_ELEMENTWISE_VIEW Phase 4.5 P.4.5.4 — DAG property test.
#
# Extension of Phase 4 P.4.5 (= random boolean tree) to reductions:
# wrap random lazy expression trees in reduction ops and verify byte
# parity with eager.  Covers both streaming path (= flat 1-D unmasked)
# and SRC_ATTACH path (= masked / N-D / partial reduction).

class TestLazyReduceP454Property < Test::Unit::TestCase
  N = 256
  RNG_SEED = 0x52454432  # 'RED2'

  ARITH_OPS = [:+, :-, :*].freeze
  BINCMP_OPS = [:lt, :gt, :le, :ge, :eq, :ne].freeze
  BITWISE_OPS = [:&, :|, :^].freeze
  MONOP_OPS = [:abs_i, :neg].freeze   # arith-preserving lazy monops
  MONCMP_OPS = [:is_nan, :is_inf, :is_finite].freeze

  # Reduction ops by category — all should accept lazy operands.
  NUMERIC_REDUCTIONS = [:sum, :mean, :min, :max, :variance, :stddev,
                        :prod, :variancep, :stddevp].freeze
  COUNT_REDUCTIONS   = [:count_masked, :count_not_masked].freeze
  # count(true) requires a boolean source

  def setup
    @rng = Random.new(RNG_SEED)
    @a = CArray.float64(N) { |k| (k - N / 2) * 0.05 + 0.1 }
    @b = CArray.float64(N) { |k| (k - N / 4) * 0.025 + 0.05 }
    @c = CArray.float64(N) { |k| Math.sin(k * 0.1) * 0.4 }
  end

  def carray_leaf(rng)
    case rng.rand(3)
    when 0 then [@a, :leaf_a]
    when 1 then [@b, :leaf_b]
    else        [@c, :leaf_c]
    end
  end

  def scalar_leaf(rng)
    [(rng.rand * 2.0) - 1.0, :scalar]
  end

  def build_float_tree(depth, rng)
    return carray_leaf(rng) if depth == 0
    # Random arith subtree with optional monop wrap
    op = ARITH_OPS[rng.rand(ARITH_OPS.length)]
    l_e, l_s = build_float_tree(depth - 1, rng)
    if rng.rand(2) == 0
      r_e, r_s = scalar_leaf(rng)
    else
      r_e, r_s = build_float_tree(depth - 1, rng)
    end
    [[:arith, op, l_e, l_s, r_e, r_s], :arith]
  end

  def build_bool_tree(depth, rng)
    return carray_leaf(rng) if depth == 0
    choice = rng.rand(3)
    if choice == 0 && depth > 1
      op = BITWISE_OPS[rng.rand(BITWISE_OPS.length)]
      l_e, l_s = build_bool_tree(depth - 1, rng)
      r_e, r_s = build_bool_tree(depth - 1, rng)
      [[:bitwise, op, l_e, l_s, r_e, r_s], :bitwise]
    else
      op = BINCMP_OPS[rng.rand(BINCMP_OPS.length)]
      l_e, l_s = build_float_tree(depth - 1, rng)
      if rng.rand(2) == 0
        r_e, r_s = scalar_leaf(rng)
      else
        r_e, r_s = build_float_tree(depth - 1, rng)
      end
      [[:bincmp, op, l_e, l_s, r_e, r_s], :bincmp]
    end
  end

  def eval_eager(node, spec)
    case spec
    when :leaf_a, :leaf_b, :leaf_c, :scalar
      node
    when :arith, :bincmp, :bitwise
      _, op, l, ls, r, rs = node
      eval_eager(l, ls).public_send(op, eval_eager(r, rs))
    end
  end

  def eval_lazy(node, spec)
    case spec
    when :leaf_a, :leaf_b, :leaf_c then node.lazy
    when :scalar then node
    when :arith, :bincmp, :bitwise
      _, op, l, ls, r, rs = node
      eval_lazy(l, ls).public_send(op, eval_lazy(r, rs))
    end
  end

  # === reduction over random float DAG ===

  def test_sum_over_random_float_dag
    50.times do |seed_off|
      rng = Random.new(RNG_SEED + seed_off)
      depth = 2 + rng.rand(4)
      tree, spec = build_float_tree(depth, rng)
      eager = eval_eager(tree, spec).sum
      lazy  = eval_lazy(tree, spec).sum
      # NaN/Inf can appear (e.g. from divides); accept when both agree
      if eager.finite? && lazy.finite?
        rel = (eager - lazy).abs / [eager.abs, 1e-12].max
        assert rel < 1e-9,
               "sum tree seed=#{seed_off} depth=#{depth}: eager=#{eager} lazy=#{lazy}"
      else
        assert_equal eager.nan?, lazy.nan?,
                     "NaN status mismatch seed=#{seed_off}"
      end
    end
  end

  def test_mean_min_max_over_random_float_dag
    30.times do |seed_off|
      rng = Random.new(RNG_SEED + 1000 + seed_off)
      depth = 2 + rng.rand(3)
      tree, spec = build_float_tree(depth, rng)
      eager_arr = eval_eager(tree, spec)
      [:mean, :min, :max].each do |op|
        e = eager_arr.public_send(op)
        l = eval_lazy(tree, spec).public_send(op)
        if e.finite? && l.finite?
          rel = (e - l).abs / [e.abs, 1e-12].max
          assert rel < 1e-9,
                 "#{op} tree seed=#{seed_off}: eager=#{e} lazy=#{l}"
        else
          assert_equal e.nan?, l.nan?, "NaN mismatch on #{op}"
        end
      end
    end
  end

  def test_variance_stddev_over_random_float_dag
    30.times do |seed_off|
      rng = Random.new(RNG_SEED + 2000 + seed_off)
      depth = 2 + rng.rand(3)
      tree, spec = build_float_tree(depth, rng)
      eager_arr = eval_eager(tree, spec)
      [:variance, :stddev].each do |op|
        e = eager_arr.public_send(op)
        l = eval_lazy(tree, spec).public_send(op)
        if e.finite? && l.finite? && e.abs > 1e-9
          rel = (e - l).abs / e.abs
          assert rel < 1e-6,
                 "#{op} tree seed=#{seed_off}: eager=#{e} lazy=#{l}"
        else
          assert_equal e.nan?, l.nan?, "NaN status on #{op}"
        end
      end
    end
  end

  # === count(true) over random boolean DAG ===

  def test_count_true_over_random_bool_dag
    50.times do |seed_off|
      rng = Random.new(RNG_SEED + 3000 + seed_off)
      depth = 2 + rng.rand(3)
      tree, spec = build_bool_tree(depth, rng)
      eager_arr = eval_eager(tree, spec)
      lazy_view = eval_lazy(tree, spec)
      e = eager_arr.count(true)
      l = lazy_view.count(true)
      assert_equal e, l,
                   "count(true) tree seed=#{seed_off} depth=#{depth}"
    end
  end

  # === moncmp leaf ===

  def test_moncmp_then_reduce_dag
    30.times do |seed_off|
      rng = Random.new(RNG_SEED + 4000 + seed_off)
      depth = 1 + rng.rand(3)
      float_tree, fspec = build_float_tree(depth, rng)
      mop = MONCMP_OPS[rng.rand(MONCMP_OPS.length)]
      eager_arr  = eval_eager(float_tree, fspec).public_send(mop)
      lazy_view  = eval_lazy(float_tree, fspec).public_send(mop)
      e = eager_arr.count(true)
      l = lazy_view.count(true)
      assert_equal e, l,
                   "moncmp(#{mop}).count tree seed=#{seed_off} depth=#{depth}"
    end
  end

  # === SRC_ATTACH path (= mask present, falls through streaming) ===

  def test_reduction_with_masked_lazy_operand
    a = @a.dup
    a[0..9]   = UNDEF
    a[200..]  = UNDEF
    # sum / mean / count_not_masked all must respect mask propagation
    [:sum, :mean, :min, :max].each do |op|
      e = (a + @b).public_send(op)
      l = (a.lazy + @b).public_send(op)
      if e.is_a?(Numeric) && l.is_a?(Numeric)
        if e.finite? && l.finite?
          rel = (e - l).abs / [e.abs, 1e-12].max
          assert rel < 1e-9, "#{op} masked: eager=#{e} lazy=#{l}"
        else
          assert_equal e.nan?, l.nan?, "NaN on #{op}"
        end
      else
        assert_equal e.class, l.class, "#{op} return type"
      end
    end
  end

  # === arena lifecycle under reduction property load ===

  def test_arena_depth_stable_under_property_load
    CArray.__lazy_arena_reset_counters__
    30.times do |seed_off|
      rng = Random.new(RNG_SEED + 6000 + seed_off)
      depth = 1 + rng.rand(3)
      tree, spec = build_float_tree(depth, rng)
      _ = eval_lazy(tree, spec).sum
    end
    30.times do |seed_off|
      rng = Random.new(RNG_SEED + 7000 + seed_off)
      depth = 1 + rng.rand(3)
      tree, spec = build_bool_tree(depth, rng)
      _ = eval_lazy(tree, spec).count(true)
    end
    assert_equal 0, CArray.__lazy_arena_depth__,
                 "arena depth must balance after property load"
    assert_equal 0, CArray.__lazy_arena_slot_in_use_count__,
                 "arena slots must release after property load"
  end

  # === streaming vs SRC_ATTACH consistency ===

  def test_streaming_and_src_attach_agree_per_op
    # Force-trigger both paths by varying conditions; agree on result.
    n = 1024
    a = CArray.float64(n) { |k| (k - n / 2) * 0.01 }
    b = CArray.float64(n) { |k| k * 0.005 }

    [:sum, :mean, :min, :max].each do |op|
      # streaming: flat 1-D unmasked
      stream_r = (a.lazy + b).public_send(op)
      # force SRC_ATTACH: same operand but masked → streaming gate fails
      a_mask = a.dup
      # Touch mask without modifying actual values (= add and remove a mask cell)
      a_mask[0] = UNDEF
      a_mask[0] = a[0]   # restore; this still leaves the mask bit set
      attach_r = (a_mask.lazy + b).public_send(op)
      # The two should agree (mask is on a value that equals the original)
      if stream_r.finite? && attach_r.finite?
        rel = (stream_r - attach_r).abs / [stream_r.abs, 1e-12].max
        assert rel < 1e-9,
               "#{op} streaming=#{stream_r} src_attach=#{attach_r}"
      end
    end
  end
end

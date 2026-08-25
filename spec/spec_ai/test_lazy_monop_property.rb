$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "test/unit"
require "carray"

# PROPOSAL_LAZY_ELEMENTWISE_VIEW Phase 1 P.1.4 — property test.
#
# Generates random monop chains and verifies byte parity vs the eager
# chain of the same ops on the same input.  Phase 1 limits the
# generator to single-source monop chains (no binop, no shared
# subexpressions); the DAG generator is Phase 2 scope when CABinOp
# enables shared subexpressions.
#
# Seeds are logged; CI failures should be reproducible.
class TestLazyMonopProperty < Test::Unit::TestCase

  ALL_NUMERIC = [CA_INT8, CA_UINT8, CA_INT16, CA_UINT16, CA_INT32,
                 CA_UINT32, CA_INT64, CA_UINT64, CA_FLOAT32, CA_FLOAT64].freeze

  # Ops grouped by input-domain safety, so we can pick a safe op for a
  # given data_type range.  Each entry is [:op_name, lambda(rng, data_type) -> sample].

  # Always-safe ops (real-domain unrestricted).  Skip bit_neg/abs_i/not
  # to avoid integer-only domain.
  ALWAYS_SAFE = %i[neg sin cos exp atan tanh sinh cosh asinh].freeze

  # Ops requiring positive input.
  POSITIVE_ONLY = %i[sqrt log log10 log2 logb acosh].freeze

  # Ops requiring |x| <= 1.
  BOUNDED_UNIT = %i[asin acos atanh].freeze

  # Ops that need finite/non-negative (no domain issue but produce
  # explosive values if input is too large).
  CARE_FOR_OVERFLOW = %i[exp exp2 exp10].freeze

  # Generate a "safe" input sample for a given data_type.  We use small
  # positive values (1..10) so all chained ops stay in valid domains
  # and don't blow up to infinity.
  def safe_sample(rng, data_type, n: 16)
    case data_type
    when CA_FLOAT32, CA_FLOAT64
      arr = CArray.new(data_type, [n])
      n.times { |i| arr[i] = 0.5 + rng.rand(0.0..2.0) }
      arr
    else
      arr = CArray.new(data_type, [n])
      n.times { |i| arr[i] = 1 + rng.rand(5) }   # 1..5 — safe for sqrt/log/etc
      arr
    end
  end

  # Generate a random chain of monop ops.  Only picks ops that are
  # safe across iterations (avoid blowing up via repeated exp etc.).
  def random_chain(rng, max_depth: 5)
    # Restrict to "always safe" + a few from positive-only to keep
    # results in a numerically stable range across the chain.
    op_pool = ALWAYS_SAFE + [:sqrt, :tanh]
    depth = rng.rand(1..max_depth)
    depth.times.map { op_pool[rng.rand(op_pool.size)] }
  end

  # Apply a chain to an array (eager).
  def apply_eager(arr, ops)
    ops.each_with_index.inject(arr) do |acc, (op, i)|
      acc.__send__(:"__#{op}_eager__")
    end
  end

  # Apply a chain via lazy.
  def apply_lazy(arr, ops)
    chain = arr.lazy
    ops.each { |op| chain = chain.send(op) }
    chain.to_ca
  end

  def test_property_random_chains
    failures = []
    seeds_run = 0
    n_seeds = 80
    n_seeds.times do |seed|
      rng = Random.new(seed)
      data_type = ALL_NUMERIC[rng.rand(ALL_NUMERIC.size)]
      ops = random_chain(rng)
      arr = safe_sample(rng, data_type)

      begin
        eager_result = apply_eager(arr, ops)
      rescue StandardError => e
        # eager couldn't handle this combo — skip
        next
      end
      seeds_run += 1

      begin
        lazy_result = apply_lazy(arr, ops)
      rescue StandardError => e
        failures << "seed=#{seed} data_type=#{data_type} ops=#{ops} — lazy raised: #{e.class}: #{e.message}"
        next
      end

      # Byte parity check — masked-cell garbage doesn't apply because
      # safe_sample doesn't introduce masks.
      unless eager_result.dump_binary == lazy_result.dump_binary
        # Float ops may have tiny FP-mode differences; check element
        # values within tolerance instead of strict bytes.
        ok = true
        eager_result.each_addr do |i|
          a, b = eager_result[i], lazy_result[i]
          # NaN handling — both NaN counts as equal.
          a_nan = a.respond_to?(:nan?) && a.nan?
          b_nan = b.respond_to?(:nan?) && b.nan?
          next if a_nan && b_nan
          if a_nan || b_nan
            ok = false
            break
          end
          tol = 1e-9 * [a.abs, b.abs, 1.0].max
          if (a - b).abs > tol
            ok = false
            break
          end
        end
        unless ok
          failures << "seed=#{seed} data_type=#{data_type} ops=#{ops}\n  eager=#{eager_result.to_a.inspect}\n  lazy=#{lazy_result.to_a.inspect}"
        end
      end
    end

    assert_operator seeds_run, :>=, 60, "too many seeds skipped"
    assert_empty failures,
      "Property test failures (#{failures.size}/#{seeds_run} seeds):\n#{failures.join("\n\n")}"
  end

  def test_property_with_mask
    # Subset of seeds, this time with random masks applied.  The lazy
    # output mask should match the eager output mask.
    failures = []
    seeds_run = 0
    50.times do |seed|
      rng = Random.new(seed + 1000)   # different seed range
      data_type = CA_FLOAT64                # only f64 to keep mask semantics simple
      ops = random_chain(rng, max_depth: 4)
      arr = safe_sample(rng, data_type, n: 20)
      # apply random mask
      arr.dim[0].times do |i|
        arr[i] = UNDEF if rng.rand < 0.2
      end

      begin
        eager_result = apply_eager(arr, ops)
      rescue StandardError
        next
      end
      seeds_run += 1

      begin
        lazy_result = apply_lazy(arr, ops)
      rescue StandardError => e
        failures << "seed=#{seed} ops=#{ops} — lazy raised: #{e.class}"
        next
      end

      # mask should propagate identically
      unless eager_result.is_masked.to_a == lazy_result.is_masked.to_a
        failures << "seed=#{seed} ops=#{ops} — mask mismatch: eager=#{eager_result.is_masked.to_a} lazy=#{lazy_result.is_masked.to_a}"
        next
      end

      # unmasked cells should match (within FP tolerance)
      arr.dim[0].times do |i|
        next if eager_result.is_masked[i]
        a, b = eager_result[i], lazy_result[i]
        if a.nan? && b.nan?
          next
        end
        if (a - b).abs > 1e-9 * ([a.abs, b.abs, 1.0].max)
          failures << "seed=#{seed} ops=#{ops} cell=#{i}: eager=#{a} lazy=#{b}"
          break
        end
      end
    end

    assert_operator seeds_run, :>=, 35, "too many masked seeds skipped"
    assert_empty failures,
      "Masked property test failures:\n#{failures.join("\n\n")}"
  end

  def test_depth_100_iterative_collect_stack_safe
    # Q5 (c): depth-100 stress as iterative-collect validation.
    # Verifies CA_MAX_LAZY_DEPTH=256 ceiling allows 100 deep without
    # blowing the C stack (which a recursive walk would do).
    a = CArray.float64(8).seq + 2.0
    chain = a.lazy
    100.times { chain = chain.sqrt }
    assert_nothing_raised { chain.to_ca }
  end
end

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "test/unit"
require "carray"

# PROPOSAL_LAZY_ELEMENTWISE_VIEW Phase 1 P.1.1 smoke tests.
#
# Scope (per Phase 1 prep doc §1 / §8):
# - CAMonOp + CALazyMarker classes exist, CA_FLAG_READ_ONLY enforced
# - in-place chain eval xfer_stride: scratch acquire counter = 0 at any depth
# - byte parity for f64 sqrt (1 case + chain)
# - readonly raise on [] =
# - eager fallback for non-lazy and non-f64
# - C stack safety: depth-100 stress
class TestLazyMonopP11 < Test::Unit::TestCase

  def test_camonop_class_exists
    assert defined?(CAMonOp), "CAMonOp class must be defined"
    assert defined?(CALazyMarker), "CALazyMarker class must be defined"
    assert CAMonOp < CAView
    assert CALazyMarker < CAView
    assert defined?(CA_OBJ_MONOP)
    assert defined?(CA_OBJ_LAZY_MARKER)
  end

  def test_lazy_marker_construction
    a = CArray.float64(5).seq
    m = a.lazy
    assert_equal CALazyMarker, m.class
    # marker is a transparent pass-through over a
    assert_equal [5], m.dim
    assert_equal CA_FLOAT64, m.data_type
    assert_equal a.to_a, m.to_ca.to_a
  end

  def test_camonop_construction_via_sqrt
    a = CArray.float64(5).seq + 1.0
    v = a.lazy.sqrt
    assert_equal CAMonOp, v.class
    assert_equal CA_FLOAT64, v.data_type
    assert_equal a.dim, v.dim
  end

  def test_camonop_readonly
    a = CArray.float64(5).seq + 1.0
    v = a.lazy.sqrt
    assert_raise(RuntimeError) { v[0] = 1.0 }
  end

  def test_sqrt_byte_parity_f64
    a = CArray.float64(20).seq + 1.0
    lazy_result = a.lazy.sqrt.to_ca
    eager       = a.sqrt
    assert_equal eager.dump_binary, lazy_result.dump_binary
  end

  def test_chain_scratch_count_0_depth_3
    a = CArray.float64(10).seq + 1.0
    CAMonOp.__reset_scratch_counter__
    result = a.lazy.sqrt.sqrt.sqrt.to_ca
    assert_equal 0, CAMonOp.__scratch_count__,
      "in-place chain eval must allocate zero scratch buffers (Q8 (B))"
    # byte parity with eager equivalent
    expected = a.sqrt.sqrt.sqrt
    assert_equal expected.dump_binary, result.dump_binary
  end

  def test_chain_scratch_count_0_depth_20
    a = CArray.float64(10).seq + 2.0
    CAMonOp.__reset_scratch_counter__
    chain = a.lazy
    20.times { chain = chain.sqrt }
    result = chain.to_ca
    assert_equal 0, CAMonOp.__scratch_count__
    # depth-20 sqrt of [2..11] should all be near 1.0
    result.each { |v| assert (v - 1.0).abs < 1e-3, "expected ~1, got #{v}" }
  end

  def test_chain_depth_100_c_stack_safe
    # Q5 (c): depth-100 stress as eval-strategy validation.
    # iterative chain collect must not blow C stack.
    a = CArray.float64(3).seq + 2.0
    chain = a.lazy
    100.times { chain = chain.sqrt }
    result = nil
    assert_nothing_raised { result = chain.to_ca }
    refute_nil result
    assert_equal [3], result.dim
  end

  def test_eager_fallback_non_lazy
    # `.sqrt` on a plain entity goes through the eager path.
    a = CArray.float64(5).seq + 1.0
    eager_direct = a.sqrt
    assert_equal CArray, eager_direct.class
    expected = [1.0, Math.sqrt(2), Math.sqrt(3), 2.0, Math.sqrt(5)]
    eager_direct.to_a.zip(expected).each do |got, exp|
      assert_in_delta exp, got, 1e-12
    end
  end

  def test_eager_fallback_int_data_type
    # int32.sqrt in P.1.1 goes through eager (cast node insertion is P.1.2).
    a = CArray.int32(5).seq
    result = a.sqrt
    assert_equal CArray, result.class
    assert_equal CA_FLOAT64, result.data_type
    expected = [0.0, 1.0, Math.sqrt(2), Math.sqrt(3), 2.0]
    result.to_a.zip(expected).each do |got, exp|
      assert_in_delta exp, got, 1e-12
    end
  end

  def test_lazy_marker_double_consume_safe
    # marker is transient — re-consuming the same marker must work
    # (collapse-on-consume doesn't mutate the marker).
    a = CArray.float64(5).seq + 1.0
    m = a.lazy
    v1 = m.sqrt
    v2 = m.sqrt
    # both should materialise to the same result
    assert_equal v1.to_ca.dump_binary, v2.to_ca.dump_binary
    # marker itself is still usable
    assert_equal a.to_a, m.to_ca.to_a
  end

  def test_lazy_on_int32_now_widens_via_cast_node
    # P.1.2: cast node insertion lifted the P.1.1 limitation.  `int32.lazy
    # .sqrt` inserts CAMonOp(:cast_f64) between sqrt and the int32 parent,
    # producing f64 output with byte parity vs eager `int32.sqrt`.
    a = CArray.int32(5).seq + 1
    v = a.lazy.sqrt
    assert_equal CAMonOp, v.class
    result = v.to_ca
    assert_equal CA_FLOAT64, result.data_type
    assert_equal a.sqrt.dump_binary, result.dump_binary
  end

  def test_to_ca_materialises
    # Read-only views use `.to_ca` as the canonical materialise path
    # (not `attach!`, since sync would attempt to push back, which is a
    # contract violation for read-only).
    a = CArray.float64(5).seq + 1.0
    v = a.lazy.sqrt
    expected = a.sqrt
    entity = v.to_ca
    assert_equal CArray, entity.class
    assert_equal expected.to_a, entity.to_a
  end
end

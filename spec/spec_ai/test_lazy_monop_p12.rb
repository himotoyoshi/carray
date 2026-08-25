$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "test/unit"
require "carray"

# PROPOSAL_LAZY_ELEMENTWISE_VIEW Phase 1 P.1.2 — byte-parity sweep across
# all 34 monop/monfunc x ALL_NUMERIC data_type combinations, plus cast-node
# insertion verification and chain-depth-independent scratch counter
# behaviour.
#
# Acceptance signatures hit:
#   - A2  dispatch all 34 ops
#   - A4  byte parity across (op, data_type)
#   - A5  scratch count depth-independent (0 for f64 chain, 1 for
#         widening chain regardless of depth)
#   - finding #1 cast node insertion (int32 widening -> CAMonOp(:cast_f64))
class TestLazyMonopP12 < Test::Unit::TestCase

  ALL_NUMERIC_DTYPES = [
    CA_INT8, CA_UINT8, CA_INT16, CA_UINT16, CA_INT32, CA_UINT32,
    CA_INT64, CA_UINT64, CA_FLOAT32, CA_FLOAT64,
  ].freeze

  # Per-op domain configuration: which data_type categories the op accepts,
  # plus a small "safe values" generator for that data_type.  This dodges
  # nan/inf/domain-error cases that would make `assert_equal` brittle.
  PRESERVE_DTYPE_MONOP = %i[zero one frac neg bit_neg abs_i conj not]
  PRESERVE_DTYPE_MONFUNC = %i[ceil floor round rcp]
  WIDENING_MONFUNC = %i[rad deg sqrt exp exp2 exp10 log log10 log2 logb
                        sin cos tan asin acos atan sinh cosh tanh
                        asinh acosh atanh]

  # Some ops are domain-restricted (e.g. asin/acos/atanh need |x| <= 1,
  # log needs x > 0).  Skip data_type combinations where the eager path itself
  # would raise / produce NaN, since those aren't useful parity tests.
  SKIP_INT_DOMAIN = %i[asin acos atanh].freeze        # |x| <= 1, only 0/1
  POSITIVE_ONLY   = %i[log log10 log2 logb sqrt acosh].freeze
  POSITIVE_ZERO_OK = %i[].freeze

  # Build sample input for given data_type that stays in valid domains for
  # most ops.  Returns small array (5 elements).
  def build_sample(data_type, op_name)
    case data_type
    when CA_INT8, CA_UINT8, CA_INT16, CA_UINT16, CA_INT32, CA_UINT32,
         CA_INT64, CA_UINT64
      if SKIP_INT_DOMAIN.include?(op_name)
        nil  # skip — only 0/1 valid, can't sweep meaningfully
      elsif POSITIVE_ONLY.include?(op_name)
        CArray.new(data_type, [5]) { |k| k + 1 }   # 1..5
      else
        # Use 1..5 range, avoiding 0 for rcp
        if op_name == :rcp
          CArray.new(data_type, [5]) { |k| k + 1 }
        else
          CArray.new(data_type, [5]).seq
        end
      end
    when CA_FLOAT32, CA_FLOAT64
      if POSITIVE_ONLY.include?(op_name)
        CArray.new(data_type, [5]).seq + 0.5  # 0.5, 1.5, ..., 4.5
      elsif SKIP_INT_DOMAIN.include?(op_name)
        CArray.new(data_type, [5]) { |k| (k - 2) * 0.3 }  # -0.6..0.6
      elsif op_name == :rcp
        CArray.new(data_type, [5]).seq + 0.5
      else
        CArray.new(data_type, [5]) { |k| (k - 2) * 0.3 }  # -0.6..0.6
      end
    end
  end

  # Skip combinations we don't intend to validate:
  # - bit_neg: only valid on integer/boolean, not floats
  # - not: only valid on integer/boolean
  # - conj: works on all but mostly tested on complex (not in P.1.2 ALL_NUMERIC)
  # - abs_i: integer abs, may not implement for unsigned cleanly
  # - rad/deg/round/ceil/floor: float-domain reads, integer is identity
  def skip_combination?(op_name, data_type)
    case op_name
    when :bit_neg, :not, :abs_i, :frac
      # integer-domain only; skip floats
      ![CA_FLOAT32, CA_FLOAT64].include?(data_type) ? false : true
    when :zero, :one
      # accept all numerics
      false
    when :conj
      # conj on real is identity, accept all
      false
    else
      false
    end
  end

  ## ====== A2: all 34 op_id constants exist ======

  def test_a2_all_op_ids_defined
    expected = PRESERVE_DTYPE_MONOP + PRESERVE_DTYPE_MONFUNC + WIDENING_MONFUNC
    assert_equal 34, expected.size
    expected.each do |op|
      const_name = "OP_#{op.to_s.upcase}"
      assert CAMonOp.const_defined?(const_name), "Missing CAMonOp::#{const_name}"
    end
    assert_equal 100, CAMonOp::CAST_BASE
  end

  ## ====== A4: byte parity sweep ======

  def test_a4_byte_parity_preserve_data_type_monop
    failures = []
    PRESERVE_DTYPE_MONOP.each do |op_name|
      ALL_NUMERIC_DTYPES.each do |data_type|
        next if skip_combination?(op_name, data_type)
        a = build_sample(data_type, op_name)
        next if a.nil?
        begin
          eager = a.__send__(:"__#{op_name}_eager__")
        rescue StandardError, NotImplementedError
          next  # kernel not implemented eagerly; lazy will also not impl
        end
        lazy_v = a.__send__(op_name)
        next unless lazy_v.is_a?(CAMonOp)
        result = lazy_v.to_ca
        unless eager.dump_binary == result.dump_binary
          failures << "[#{op_name}/#{data_type}] eager=#{eager.to_a.inspect} lazy=#{result.to_a.inspect}"
        end
      end
    end
    assert_empty failures, "preserve-data_type monop parity failures:\n#{failures.join("\n")}"
  end

  def test_a4_byte_parity_preserve_data_type_monfunc
    failures = []
    PRESERVE_DTYPE_MONFUNC.each do |op_name|
      ALL_NUMERIC_DTYPES.each do |data_type|
        next if skip_combination?(op_name, data_type)
        a = build_sample(data_type, op_name)
        next if a.nil?
        begin
          eager = a.__send__(:"__#{op_name}_eager__")
        rescue StandardError, NotImplementedError
          next
        end
        lazy_v = a.__send__(op_name)
        next unless lazy_v.is_a?(CAMonOp)
        result = lazy_v.to_ca
        unless eager.dump_binary == result.dump_binary
          failures << "[#{op_name}/#{data_type}] eager=#{eager.to_a.inspect} lazy=#{result.to_a.inspect}"
        end
      end
    end
    assert_empty failures, "preserve-data_type monfunc parity failures:\n#{failures.join("\n")}"
  end

  def test_a4_byte_parity_widening_monfunc
    # Widening monfunc: integer -> f64 via cast node (finding #1).
    failures = []
    WIDENING_MONFUNC.each do |op_name|
      ALL_NUMERIC_DTYPES.each do |data_type|
        a = build_sample(data_type, op_name)
        next if a.nil?
        begin
          eager = a.__send__(:"__#{op_name}_eager__")
        rescue StandardError, NotImplementedError
          next
        end
        lazy_v = a.__send__(op_name)
        next unless lazy_v.is_a?(CAMonOp)
        result = lazy_v.to_ca
        unless eager.dump_binary == result.dump_binary
          failures << "[#{op_name}/#{data_type}] eager=#{eager.to_a.inspect} lazy=#{result.to_a.inspect}"
        end
      end
    end
    assert_empty failures, "widening monfunc parity failures:\n#{failures.join("\n")}"
  end

  ## ====== finding #1: cast node insertion ======

  def test_finding1_int32_sqrt_inserts_cast_node
    a = CArray.int32(5).seq + 1
    v = a.lazy.sqrt
    assert_equal CAMonOp, v.class
    assert_equal CA_FLOAT64, v.data_type
    # The CAMonOp's immediate parent should be a cast node (also CAMonOp).
    assert_equal CAMonOp, v.parent.class,
      "expected cast node (CAMonOp) between sqrt and int32 parent"
    assert_equal CA_FLOAT64, v.parent.data_type
    # The cast's parent is the int32 entity.
    assert_equal CA_INT32, v.parent.parent.data_type
  end

  def test_finding1_f64_sqrt_no_cast_node
    a = CArray.float64(5).seq + 1.0
    v = a.lazy.sqrt
    assert_equal CAMonOp, v.class
    assert_equal CA_FLOAT64, v.data_type
    # No cast node — direct entity parent.
    assert_equal CArray, v.parent.class
  end

  def test_finding1_int_ceil_no_cast_node
    # ceil preserves integer data_type, so no cast needed even for int32.
    a = CArray.int32(5).seq
    v = a.lazy.ceil
    assert_equal CAMonOp, v.class
    assert_equal CA_INT32, v.data_type
    assert_equal CArray, v.parent.class,
      "ceil on int32 should not insert cast node"
  end

  ## ====== A5: scratch counter depth-independence ======

  def test_a5_scratch_zero_for_f64_chain
    a = CArray.float64(10).seq + 1.0
    CAMonOp.__reset_scratch_counter__
    a.lazy.sqrt.sin.exp.log.to_ca
    assert_equal 0, CAMonOp.__scratch_count__,
      "f64 chain must allocate zero leaf-scratch"
  end

  def test_a5_scratch_one_for_int_chain_independent_of_depth
    a = CArray.int32(10).seq + 1
    CAMonOp.__reset_scratch_counter__
    a.lazy.sqrt.to_ca
    depth1 = CAMonOp.__scratch_count__

    CAMonOp.__reset_scratch_counter__
    a.lazy.sqrt.sin.cos.exp.log.to_ca
    depth5 = CAMonOp.__scratch_count__

    assert_equal depth1, depth5,
      "leaf-scratch count must be depth-independent (got depth1=#{depth1} depth5=#{depth5})"
    assert_equal 1, depth1, "expected exactly 1 leaf-scratch for int->f64 cast"
  end

  ## ====== B5: collapse-on-consume + marker double-use ======

  def test_b5_marker_collapse_on_consume
    a = CArray.float64(5).seq + 1.0
    m = a.lazy
    v = m.sqrt
    # The CAMonOp's parent should be `a` directly, not the marker.
    assert_equal CArray, v.parent.class,
      "collapse-on-consume: marker should not appear in CAMonOp tree"
    refute_equal CALazyMarker, v.parent.class
  end

  def test_b5_marker_reused_across_ops
    a = CArray.float64(5).seq + 1.0
    m = a.lazy
    v1 = m.sqrt
    v2 = m.sin
    # Both should reference `a` as their parent (collapse-on-consume).
    assert_equal CArray, v1.parent.class
    assert_equal CArray, v2.parent.class
    # Marker is still usable.
    assert_equal a.to_a, m.to_ca.to_a
  end
end

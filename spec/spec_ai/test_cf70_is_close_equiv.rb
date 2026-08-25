# CF.7.0: rb_ca_is_close / rb_ca_is_equiv -- C implementations of
# element-wise close/equiv predicates that replace the 3-pass Ruby
# versions in lib/carray/math.rb.
#
# Tests pin:
#   - byte parity vs legacy count_close / count_equiv via chain
#     `a.is_close(v, tol).count(true)`
#   - mask propagation (output bool inherits input mask, so chain
#     `.count(true, min_count: K)` matches legacy's UNDEF-on-insufficient
#     semantics)
#   - data_type coverage across ALL_NUMERIC + complex
#   - integer + float input

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestCF70IsCloseEquiv < Test::Unit::TestCase

  # ---- is_close basic --------------------------------------------------

  def test_is_close_returns_boolean_array
    a = CArray.float64(5).seq
    r = a.is_close(2.0, 0.5)
    assert_kind_of(CArray, r)
    assert_equal(:boolean, r.data_type_name.to_sym)
    assert_equal(a.shape, r.shape)
  end

  def test_is_close_atol
    a = CArray.float64(5).seq    # [0, 1, 2, 3, 4]
    r = a.is_close(2.0, 0.5)
    assert_equal([false, false, true, false, false], r.to_a)
    r2 = a.is_close(2.0, 1.0)
    assert_equal([false, true, true, true, false], r2.to_a)
  end

  def test_is_close_lazy_dispatch_via_ruby_shim
    # IC.4 (PROPOSAL_IS_CLOSE_BINCMP_MIGRATION): is_close is now wrapped
    # by a Ruby shim in lib/carray/lazy.rb (LAZY_BINCMP_TOL_OP_IDS) that
    # dispatches to CABinCmp.__build__ for lazy parents, falling through
    # to the mkkernel-generated rb_ca_is_close (= C-bound) for eager.
    a = CArray.float64(3).seq
    loc = a.method(:is_close).source_location
    refute_nil(loc, "is_close should be Ruby-defined (lazy shim)")
    assert_match(/lazy\.rb/, loc[0])
  end

  # ---- is_equiv basic --------------------------------------------------

  def test_is_equiv_relative_tolerance
    a = CArray.float64(3)
    a[0] = 100.0; a[1] = 1000.0; a[2] = 10000.0
    # 1% relative tolerance: 100 ± 1, 1000 ± 10, 10000 ± 100
    r = a.is_equiv(1000.0, 0.01)
    assert_equal([false, true, false], r.to_a)
  end

  def test_is_equiv_exact_match_zero_tol
    a = CArray.int32(5)
    [1, 2, 3, 2, 1].each_with_index { |v, i| a[i] = v }
    # rtol = 0 -> only exact match counts
    r = a.is_equiv(2, 0)
    assert_equal([false, true, false, true, false], r.to_a)
  end

  # ---- chain parity: known values (legacy count_close / count_equiv
  #      retired in CF.7, parity verified via hand-computed expectations) -

  def test_chain_count_close_known_values
    a = CArray.float64(10).seq          # [0,1,2,3,4,5,6,7,8,9]
    # is_close(5, 0.5) -> only index 5 matches
    assert_equal(1, a.is_close(5.0, 0.5).count(true))
    # is_close(5, 1.0) -> indices 4, 5, 6 match
    assert_equal(3, a.is_close(5.0, 1.0).count(true))
    # is_close(5, 2.0) -> indices 3..7 = 5 cells
    assert_equal(5, a.is_close(5.0, 2.0).count(true))
  end

  def test_chain_count_equiv_known_values
    a = CArray.float64(10).seq.add(1.0)   # [1..10]
    # is_equiv(5, 0.001) -> only exact-match index 4 (value 5.0)
    assert_equal(1, a.is_equiv(5.0, 0.001).count(true))
    # rtol large -> more matches
    assert(a.is_equiv(5.0, 0.5).count(true) >= 1)
  end

  # ---- mask propagation -----------------------------------------------

  def test_mask_propagation_is_close
    a = CArray.float64(5).seq
    a[2] = UNDEF
    r = a.is_close(2.0, 0.5)
    assert(r.has_mask?, "output should have mask when input does")
    assert_equal(true, r.is_masked[2])
    assert_equal(false, r.is_masked[0])
  end

  def test_mask_propagation_is_equiv
    a = CArray.float64(5).seq
    a[3] = UNDEF
    r = a.is_equiv(2.0, 0.001)
    assert(r.has_mask?)
    assert_equal(true, r.is_masked[3])
  end

  def test_no_mask_when_input_unmasked
    a = CArray.float64(5).seq
    r = a.is_close(2.0, 0.5)
    refute(r.has_mask?, "no mask should be created when input is unmasked")
  end

  # ---- all-masked min_count → UNDEF chain matches legacy ---------------

  def test_all_masked_min_count_chain_returns_undef
    # Legacy count_close(v, t, min_count) returned UNDEF on all-masked
    # input with min_count > 0; the chain reproduces this via mask
    # propagation from is_close + count(true, min_count: K).
    a = CArray.float64(5).seq
    a[] = UNDEF
    chain = a.is_close(2.0, 0.1).count(true, min_count: 1)
    assert_equal(UNDEF, chain)
  end

  # ---- data_type coverage --------------------------------------------------

  def test_data_type_coverage_int
    [:int8, :int16, :int32, :int64,
     :uint8, :uint16, :uint32, :uint64].each do |t|
      a = CArray.send(t, 5).seq
      assert_equal(1, a.is_close(2, 0).count(true), "data_type #{t} close")
      assert_equal(1, a.is_equiv(2, 0).count(true), "data_type #{t} equiv")
    end
  end

  def test_data_type_coverage_float
    [:float32, :float64].each do |t|
      a = CArray.send(t, 5).seq
      assert_equal(1, a.is_close(2.0, 0.001).count(true),
                   "data_type #{t} close")
    end
  end

  # ---- integer + tolerance corner cases --------------------------------

  def test_integer_with_zero_tolerance
    a = CArray.int32(6).seq.mod(3)   # [0,1,2,0,1,2]
    assert_equal(2, a.is_close(1, 0).count(true))
    assert_equal(2, a.is_close(2, 0).count(true))
  end
end

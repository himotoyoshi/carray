# Boolean support for the second wave of numeric/order methods, unlocked
# after the discovery family (test_boolean_discovery.rb).  Boolean storage is
# uint8 0/1; each method treats it as its 0/1 numeric value:
#
#   - partition_copy : rides the u8 quickselect, output stays boolean (values
#                      0/1, no arithmetic).  Fixes the asymmetry with
#                      partition_index, which already accepted boolean.
#   - fma / fms      : arithmetic triop; bool op bool promotes to i64 (same
#                      rule as binop `b1 * b2 + b3`), so the result can exceed
#                      1 / reach negative.  fma! / fms! stay unsupported (can't
#                      widen a boolean array in place).
#   - median / percentile / quantile : ride the f64 lane (0/1 -> 0.0/1.0), so
#                      they interpolate and return floats, matching integer
#                      input (numpy allows median but errors on percentile of
#                      bool; CArray is consistent across all three).
#   - search family  : bsearch / search / search_nearest (+ _addr) on a sorted
#                      boolean array; false < true.
#   - accumulate     : output: :preserve keeps boolean, so it is XOR-reduce
#                      (parity, mod-2 overflow) = whether an odd number of
#                      trues.  `sum` remains the widening count-of-trues (u64).

require "test/unit"
require "carray"

class TestBooleanNumericExt < Test::Unit::TestCase

  # ---- partition_copy -----------------------------------------------------

  def test_partition_copy_keeps_boolean
    b = CA_BOOLEAN([true, false, true, true, false])   # 2 falses, 3 trues
    out = b.partition_copy(2)
    assert_equal CA_BOOLEAN, out.data_type
    # kth=2 is the boundary between the false block and the true block
    assert_equal [false, false, true, true, true], out.to_a
    assert_equal true, out[2]   # kth element sits in its final sorted position
  end

  def test_partition_copy_index_consistency
    # partition_index already accepted boolean; partition_copy now matches
    b = CA_BOOLEAN([true, false, true, false, true])
    assert_nothing_raised { b.partition_index(2) }
    assert_nothing_raised { b.partition_copy(2) }
  end

  # ---- fma / fms (i64 promotion) -----------------------------------------

  def test_fma_promotes_to_i64
    a = CA_BOOLEAN([true,  false, true,  true,  false])
    b = CA_BOOLEAN([false, true,  true,  false, true])
    c = CA_BOOLEAN([true,  true,  false, false, true])
    r = a.fma(b, c)                      # a*b + c
    assert_equal CA_INT64, r.data_type
    assert_equal [1, 1, 1, 0, 1], r.to_a
    assert_equal (a * b + c).to_a, r.to_a   # consistent with the binop chain
  end

  def test_fms_reaches_negative
    a = CA_BOOLEAN([true,  false, true,  true])
    b = CA_BOOLEAN([false, true,  true,  false])
    c = CA_BOOLEAN([true,  true,  false, false])
    r = a.fms(b, c)                      # a*b - c
    assert_equal CA_INT64, r.data_type
    assert_equal [-1, -1, 1, 0], r.to_a
  end

  def test_fma_bang_stays_unsupported
    # in-place can't widen a boolean array to i64
    a = CA_BOOLEAN([true, false])
    assert_raise(CArray::DataTypeError) { a.fma!(a, a) }
  end

  # ---- median / percentile / quantile (f64 lane) -------------------------

  def test_median_returns_float
    assert_equal 1.0, CA_BOOLEAN([true, false, true, true, false]).median
    assert_equal 0.5, CA_BOOLEAN([true, false]).median   # even count interpolates
  end

  def test_percentile_returns_float
    b = CA_BOOLEAN([true, false, true, true, false])
    assert_equal 1.0, b.percentile(50)
    assert_equal 0.0, b.percentile(25)
  end

  def test_quantile_five_number_summary
    b = CA_BOOLEAN([true, false, true, true, false])
    assert_equal [0.0, 0.0, 1.0, 1.0, 1.0], b.quantile
  end

  def test_median_per_axis
    m = CA_BOOLEAN([[true, false], [true, true]])
    assert_equal [0.5, 1.0], m.median(axis: 1).to_a
  end

  def test_median_masked_flat
    b = CA_BOOLEAN([true, false, true])
    b[1] = UNDEF
    assert_equal 1.0, b.median   # present values [true, true]
  end

  # ---- search family (sorted boolean, false < true) ----------------------

  def test_bsearch
    s = CA_BOOLEAN([false, false, true, true])
    assert_equal 2, s.bsearch(true)
    assert_not_nil s.bsearch(false)
  end

  def test_search_and_nearest
    s = CA_BOOLEAN([false, false, true, true])
    assert_equal 2, s.search(true)
    assert_equal 2, s.search_nearest(true)
    assert_equal 2, s.bsearch_addr(true)
  end

  # ---- accumulate = parity (XOR-reduce) ----------------------------------

  def test_accumulate_parity
    assert_equal 1, CA_BOOLEAN([true]).accumulate
    assert_equal 0, CA_BOOLEAN([true, true]).accumulate           # even
    assert_equal 0, CA_BOOLEAN([true, false, true]).accumulate    # 2 trues, even
    assert_equal 1, CA_BOOLEAN([true, true, true]).accumulate     # 3 trues, odd
  end

  def test_accumulate_keeps_boolean_per_axis
    m = CA_BOOLEAN([[true, true, true], [true, false, false]])
    out = m.accumulate(axis: 1)
    assert_equal CA_BOOLEAN, out.data_type
    assert_equal [true, true], out.to_a   # row0: 3 trues -> 1; row1: 1 true -> 1
  end

  def test_accumulate_all_masked_identity
    b = CA_BOOLEAN([true, false])
    b[nil] = UNDEF
    assert_equal 0, b.accumulate   # empty fold -> additive identity 0
  end

  def test_sum_stays_widening_count
    # sum is the count-of-trues (u64), distinct from accumulate's parity
    assert_equal 3, CA_BOOLEAN([true, true, true]).sum
  end
end

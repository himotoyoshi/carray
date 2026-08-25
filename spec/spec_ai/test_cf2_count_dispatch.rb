# CF.2: CArray#count(v) dispatch test.
#
# Verifies the new count Ruby surface (PROPOSAL_COUNT_FAMILY.md rev3
# sparring round 1):
#   - Q1 UNDEF      -> NotImplementedError (pending CF.6)
#   - Q2 array v    -> NotImplementedError (pending CF.5)
#   - Q3 bool strict -> bool self requires true/false; numeric self
#                       rejects true/false; cross-type -> TypeError
#   - Q4 no-arg     -> count_not_masked (3.0 arity-0 rung)
#
# Functional dispatch:
#   numeric self + numeric v -> count_equal_ki (CF.1)
#   bool self + true         -> count_true_ki  (E.6a)
#   bool self + false        -> count_false_ki (E.6a)
#
# Pinned for regression once CF.7 removes legacy count_equal/equiv/close.

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"

# === CARRAY_DEV_BUILD guard (auto-added by S.7) ===
# This test exercises smoke surface gated by -DCARRAY_DEV_BUILD.
# Rebuild with `CARRAY_DEV=1 rake build_ext` to enable.
unless CArray.respond_to?(:t1_smoke)
  warn "skipping #{File.basename(__FILE__)}: requires CARRAY_DEV_BUILD"
  return
end
require "test/unit"

class TestCF2CountDispatch < Test::Unit::TestCase

  # ---- numeric + numeric ----------------------------------------------

  def test_numeric_count_basic
    a = CArray.int32(10).seq
    assert_equal(1, a.count(5))
    assert_equal(0, a.count(99))
    assert_equal(1, a.count(0))
  end

  def test_numeric_count_per_axis
    b = CArray.int32(3, 4).seq.mod(3)
    r = b.count(0, axis: 0)
    assert_equal([4],          r.shape)
    assert_equal([1, 1, 1, 1], r.to_a)
  end

  def test_numeric_count_with_min_count
    a = CArray.int32(10).seq
    a[3] = UNDEF
    a[5] = UNDEF
    # 8 valid cells, min_count 5 -> OK, 0 matches for 3 (masked)
    assert_equal(0, a.count(3, min_count: 5))
    # 8 valid, min_count 20 -> UNDEF
    assert_equal(UNDEF, a.count(3, min_count: 20))
    # fill_value substitutes UNDEF
    assert_equal(-1, a.count(3, min_count: 20, fill_value: -1))
  end

  def test_numeric_count_data_type_coverage
    [:int8, :int16, :int32, :int64,
     :uint8, :uint16, :uint32, :uint64,
     :float32, :float64].each do |t|
      a = CArray.send(t, 10).seq
      assert_equal(1, a.count(5), "data_type #{t} failed")
      assert_equal(0, a.count(99), "data_type #{t} failed")
    end
  end

  # ---- bool dispatch --------------------------------------------------

  def test_bool_count_true_false
    b = CArray.int32(10).seq.mod(2).ne(0)
    # b = [F, T, F, T, F, T, F, T, F, T]
    assert_equal(5, b.count(true))
    assert_equal(5, b.count(false))
  end

  def test_bool_count_per_axis
    # 3x4 boolean: each row alternating
    b = CArray.int32(3, 4).seq.mod(2).ne(0)
    rt = b.count(true, axis: 0)   # axis 0 reduce
    rf = b.count(false, axis: 0)
    assert_kind_of(CArray, rt)
    assert_equal([4], rt.shape)
    assert_equal([4], rf.shape)
    # each column has 3 cells, true/false totals sum to 3
    rt.each_with_index do |t, i|
      assert_equal(3, t + rf[i], "column #{i} total mismatch")
    end
  end

  def test_bool_count_with_min_count
    b = CArray.int32(10).seq.mod(2).ne(0)
    assert_equal(5, b.count(true, min_count: 5))
    assert_equal(UNDEF, b.count(true, min_count: 20))
  end

  # ---- Q3 strict dispatch (TypeError) ---------------------------------

  def test_q3_numeric_rejects_true
    a = CArray.int32(5).seq
    assert_raise(TypeError) { a.count(true) }
  end

  def test_q3_numeric_rejects_false
    a = CArray.int32(5).seq
    assert_raise(TypeError) { a.count(false) }
  end

  def test_q3_bool_accepts_1_and_0
    # boolean stores 0/1, so count accepts the integer literals 1 / 0 as
    # aliases for true / false (in addition to true / false themselves).
    b = CArray.int32(5).seq.ne(0)   # [F, T, T, T, T]
    assert_equal(b.count(true),  b.count(1))
    assert_equal(b.count(false), b.count(0))
    assert_equal(4, b.count(1))
    assert_equal(1, b.count(0))
  end

  def test_q3_bool_rejects_other_integers
    # only 1 / 0 (and true / false) are in the boolean domain.
    b = CArray.int32(5).seq.ne(0)
    assert_raise(TypeError) { b.count(2) }
    assert_raise(TypeError) { b.count(-1) }
  end

  def test_q3_bool_rejects_float
    # 1.0 is not one of true / false / 1 / 0 -- still rejected.
    b = CArray.int32(5).seq.ne(0)
    assert_raise(TypeError) { b.count(1.0) }
    assert_raise(TypeError) { b.count(0.0) }
  end

  # ---- Q4 no-arg -> count_not_masked (3.0 arity-0 rung) ---------------
  # count with no value argument is present-cell cardinality ("how many
  # are there"), the arity-0 rung of the dispatch ladder.  It forwards to
  # count_not_masked (was ArgumentError pre-3.0).

  def test_q4_no_arg_forwards_to_count_not_masked
    a = CArray.int32(5).seq
    a[2] = UNDEF
    assert_kind_of(Integer, a.count)
    assert_equal(4, a.count)
    assert_equal(a.count_not_masked, a.count)
  end

  def test_q4_no_arg_no_mask
    a = CArray.int32(5).seq
    assert_equal(5, a.count)
    assert_equal(a.count_not_masked, a.count)
  end

  def test_q4_no_arg_axis_forwards_to_count_not_masked
    a = CArray.int32(2, 3).seq
    a[0, 1] = UNDEF
    r = a.count(axis: 1)
    assert_kind_of(CArray, r)
    assert_equal(CA_INT64, r.data_type)
    assert_equal(a.count_not_masked(axis: 1).to_a, r.to_a)
    assert_equal(a.count_not_masked(axis: 0).to_a, a.count(axis: 0).to_a)
  end

  # ---- Q1 UNDEF dispatch (CF.4 / CF.6 landed: forwards to count_masked) -

  def test_q1_undef_forwards_to_count_masked
    # CF.4 wired count(UNDEF) -> count_masked (Q1 sparring confirmed).
    # Detailed semantics pinned in test_cf6_count_mask_state.rb.
    a = CArray.int32(5).seq
    a[2] = UNDEF
    assert_equal(1, a.count(UNDEF))
    assert_equal(a.count_masked, a.count(UNDEF))
  end

  # ---- Q2 CArray v broadcast (CF.5 landed: (β) trailing append) -------

  def test_q2_carray_v_broadcast
    # CF.5 wired count(v: CArray) to (β) broadcast (Q2 sparring
    # confirmed).  Detailed semantics pinned in test_cf5_count_broadcast.
    a = CArray.int32(5).seq
    v = CArray.int32(3); v[0]=1; v[1]=2; v[2]=3
    r = a.count(v)
    assert_kind_of(CArray, r)
    assert_equal([3], r.shape)
    assert_equal([1, 1, 1], r.to_a)
  end

  # ---- Face gate (a time array counts by its own values) ---------------

  def face_time
    t = CArray.time(["2024-01-01", "2024-01-02", "2024-01-01", "2024-01-03"],
                    unit: :D)
    t[3] = UNDEF
    t
  end

  def test_face_counts_an_element_and_a_ruby_time
    require "time"
    t = face_time
    assert_equal(2, t.count(t[0]))                        # CATime::Element
    assert_equal(2, t.count(Time.utc(2024, 1, 1)))        # Ruby Time
    assert_equal(1, t.count(t[1]))
  end

  def test_face_counts_a_face_array_query_by_broadcast
    t = face_time
    assert_equal([2, 1], t.count(t[0..1]).to_a)
  end

  def test_face_reconciles_a_cross_unit_query
    t = face_time
    q = CArray.time(["2024-01-01"], unit: :h)             # finer unit, on grid
    assert_equal([2], t.count(q).to_a)
  end

  def test_face_count_with_axis
    m = CArray.int64(2, 2) { |i, j| 19723 + j }.time(unit: :D)
    q = CArray.time(["2024-01-01"], unit: :D)[0]
    assert_equal([1, 1], m.count(q, axis: 1).to_a)
  end

  def test_face_mask_state_counts_are_untouched
    t = face_time
    assert_equal(3, t.count)          # present cells
    assert_equal(1, t.count(UNDEF))   # masked cells
  end

  def test_face_refuses_a_bare_storage_query
    # Same discipline as the search family: a bare number must not reach the
    # hidden storage implicitly.  `.parent` is the explicit way in.
    t = face_time
    assert_raise(TypeError) { t.count(19723) }
    assert_equal(2, t.parent.count(t.parent[0]))
  end

  # ---- Consistency with count_true_ki ----------------------------------

  def test_consistency_with_count_true_ki_internal
    # CF.7: legacy count_true / count_false bindings removed.  Verify
    # that count(true) / count(false) on bool data_type still routes through
    # the internal count_true_ki / count_false_ki kernels (= mkkernel
    # E.6a output, still emitted but no longer Ruby-bound) by comparing
    # to a direct eq()-chain that bypasses the bool kernel entry.
    b = CArray.int32(30).seq.mod(3).ne(0)
    # bool count of true matches the eq-chain count
    assert_equal(b.eq(true).count(true), b.count(true))
    assert_equal(b.eq(false).count(true), b.count(false))
  end
end

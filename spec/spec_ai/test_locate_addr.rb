require "test/unit"
require "carray"

# Tests for locate_addr / locate_nearest_addr after the 3.0 refactor.
#
# Contract pinned here:
#   - both return shape == self.shape, value space == ref index
#   - OOB self values (= not in ref / outside ref range for nearest)
#     propagate as MASKED cells (= via project's OOB-mask semantic)
#   - locate_nearest_addr direction: keyword accepts only :round/:floor/:ceil
#     (3.0 breaking: was "round" string)
#
# Use case being protected: ref-grid scatter
#   idx = obs_time.locate_addr(ref_time)
#   new_data[idx, ...] = obs_data
# OOB obs cells must stay UNDEF in new_data (= not silently overwrite ref[0]
# or wrap via negative indexing).

class TestMatchup < Test::Unit::TestCase
  def test_locate_addr_exact_match
    ref = CA_DOUBLE([0.0, 1.0, 2.0, 3.0, 4.0])
    self_ca = CA_DOUBLE([2.0, 4.0, 0.0])
    r = self_ca.locate_addr(ref)
    assert_equal [2, 4, 0], r.to_a
    assert_equal false, r.has_mask?
  end

  def test_locate_addr_oob_masks
    ref = CA_DOUBLE([0.0, 10.0, 20.0, 30.0, 40.0, 50.0])
    s = CA_DOUBLE([10.0, 30.0, 99.0, -5.0, 50.0])
    r = s.locate_addr(ref)
    assert_equal true, r.has_mask?
    assert_equal [false, false, true, true, false], r.mask.to_a
    # unmasked cells carry the right ref index
    assert_equal 1, r[0]
    assert_equal 3, r[1]
    assert_equal 5, r[4]
  end

  def test_locate_addr_unsorted_ref
    ref = CA_DOUBLE([30.0, 10.0, 50.0, 0.0, 20.0, 40.0])
    s = CA_DOUBLE([10.0, 30.0, 50.0])
    r = s.locate_addr(ref)
    # value at ref[idx] == self
    s.elements.times { |i| assert_equal s[i], ref[r[i]] }
  end

  # Regression: a fractional query against an integer ref must reconcile both
  # sides via the single-source promotion rule (CArray.result_type), so 1.5 is
  # compared at float and finds no exact match (masked), rather than truncating
  # the query to 1 and falsely matching ref[0].
  def test_locate_addr_float_query_int_ref_no_truncation
    ref  = CA_INT32([1, 2, 3])
    q    = CA_DOUBLE([1.5, 2.0])
    addr = q.locate_addr(ref)
    assert_equal true, addr.has_mask?
    assert_equal [true, false], addr.mask.to_a   # 1.5 masked (no match), 2.0 matched
    assert_equal 1, addr[1]               # 2.0 -> ref[1]
  end

  def test_locate_nearest_addr_round
    ref = CA_DOUBLE([0.0, 10.0, 20.0, 30.0, 40.0, 50.0])
    s = CA_DOUBLE([12.0, 27.0, 8.0])
    r = s.locate_nearest_addr(ref)
    assert_equal [1, 3, 1], r.to_a       # 12->10, 27->30, 8->10
    assert_equal false, r.has_mask?
  end

  def test_locate_nearest_addr_floor
    ref = CA_DOUBLE([0.0, 10.0, 20.0, 30.0, 40.0, 50.0])
    s = CA_DOUBLE([12.0, 27.0, 8.0])
    r = s.locate_nearest_addr(ref, direction: :floor)
    assert_equal [1, 2, 0], r.to_a
  end

  def test_locate_nearest_addr_ceil
    ref = CA_DOUBLE([0.0, 10.0, 20.0, 30.0, 40.0, 50.0])
    s = CA_DOUBLE([12.0, 27.0, 8.0])
    r = s.locate_nearest_addr(ref, direction: :ceil)
    assert_equal [2, 3, 1], r.to_a
  end

  def test_locate_nearest_addr_oob_masks
    ref = CA_DOUBLE([0.0, 10.0, 20.0, 30.0, 40.0, 50.0])
    s = CA_DOUBLE([12.0, 999.0, -50.0, 35.0])
    r = s.locate_nearest_addr(ref)
    assert_equal true, r.has_mask?
    assert_equal [false, true, true, false], r.mask.to_a
    assert_equal 1, r[0]   # 12 -> 10 (idx 1)
    assert_equal 4, r[3]   # 35 -> 40 (idx 4) under :round (35 == midpoint, round-half-up)
  end

  def test_locate_nearest_addr_masked_query_masks
    # A masked query is undetermined, so its address is undetermined.  The
    # value sitting under the mask must not produce a match of its own.
    ref = CA_DOUBLE([0.0, 10.0, 20.0, 30.0])
    s = CA_DOUBLE([12.0, 21.0, 29.0])
    s[1] = UNDEF
    r = s.locate_nearest_addr(ref)
    assert_equal [false, true, false], r.mask.to_a
    assert_equal 1, r[0]   # 12 -> 10 (idx 1)
    assert_equal 3, r[2]   # 29 -> 30 (idx 3)
  end

  def test_locate_nearest_addr_rejects_bogus_direction
    ref = CA_DOUBLE([0.0, 10.0])
    s = CA_DOUBLE([5.0])
    assert_raise(ArgumentError) { s.locate_nearest_addr(ref, direction: :nearest) }
    assert_raise(ArgumentError) { s.locate_nearest_addr(ref, direction: "round") }
    assert_raise(ArgumentError) { s.locate_nearest_addr(ref, direction: nil) }
  end

  # tolerance: masks cells whose |ref[addr] - self| exceeds the bound.
  def test_locate_nearest_addr_tolerance_accepts_within
    ref = CA_DOUBLE([10.0, 20.0, 30.0, 40.0, 50.0])
    s = CA_DOUBLE([15.0, 33.0])  # dist to nearest = 5, 3
    r = s.locate_nearest_addr(ref, tolerance: 5.0)
    assert_equal [1, 2], r.to_a
    assert_equal false, r.has_mask? && r.mask.to_a.any? { |m| m != 0 }
  end

  def test_locate_nearest_addr_tolerance_rejects_beyond
    ref = CA_DOUBLE([10.0, 20.0, 30.0, 40.0, 50.0])
    s = CA_DOUBLE([15.0, 33.0])  # dist to nearest = 5, 3
    r = s.locate_nearest_addr(ref, tolerance: 4.0)
    assert_equal true, r.has_mask?
    assert_equal [true, false], r.mask.to_a
    assert_equal 2, r[1]  # 33 → 30, dist 3 ≤ 4, kept
  end

  def test_locate_nearest_addr_tolerance_zero_only_exact
    ref = CA_DOUBLE([10.0, 20.0, 30.0, 40.0, 50.0])
    s = CA_DOUBLE([20.0, 25.0, 40.0])
    r = s.locate_nearest_addr(ref, tolerance: 0.0)
    assert_equal true, r.has_mask?
    assert_equal [false, true, false], r.mask.to_a
    assert_equal 1, r[0]  # 20 exact
    assert_equal 3, r[2]  # 40 exact
  end

  def test_locate_nearest_addr_tolerance_preserves_oob_mask
    ref = CA_DOUBLE([10.0, 20.0, 30.0])
    s = CA_DOUBLE([15.0, 100.0])
    r = s.locate_nearest_addr(ref, tolerance: 3.0)
    assert_equal true, r.has_mask?
    # 15 → 10 or 20 (dist 5), > tolerance 3 → masked
    # 100 → OOB → masked
    assert_equal [true, true], r.mask.to_a
  end

  def test_locate_nearest_addr_tolerance_composes_with_direction
    ref = CA_DOUBLE([10.0, 20.0, 30.0, 40.0, 50.0])
    s = CA_DOUBLE([15.0, 25.0])   # 15→10 (:floor), 25→20 (:floor)
    r_floor = s.locate_nearest_addr(ref, direction: :floor, tolerance: 6.0)
    assert_equal [0, 1], r_floor.to_a
    # tolerance 4 rejects 15→10 (dist 5) but keeps 25→20 (dist 5)? both dist 5 → both rejected
    r_floor_strict = s.locate_nearest_addr(ref, direction: :floor, tolerance: 4.0)
    assert_equal [true, true], r_floor_strict.mask.to_a
    # :ceil snaps 15→20 (dist 5), 25→30 (dist 5)
    r_ceil = s.locate_nearest_addr(ref, direction: :ceil, tolerance: 6.0)
    assert_equal [1, 2], r_ceil.to_a
  end

  # The load-bearing scatter pattern: ref-grid alignment with OOB safety.
  # Drop unmatched obs cells before scattering -- the mask on idx is the
  # signal that lets the caller filter both sides consistently.
  def test_locate_addr_drives_safe_scatter
    obs_time = CA_DOUBLE([10.0, 30.0, 999.0, 50.0])
    ref_time = CA_DOUBLE([0.0, 10.0, 20.0, 30.0, 40.0, 50.0])
    obs_vals = CA_DOUBLE([1.0, 2.0, 3.0, 4.0])
    idx = obs_time.locate_addr(ref_time)
    keep = idx.is_not_masked                  # boolean mask of matchable obs
    new_data = CArray.float64(ref_time.elements) { UNDEF }
    new_data[idx[keep]] = obs_vals[keep]
    assert_equal [1.0, 2.0, 4.0],
                 [new_data[1], new_data[3], new_data[5]]
    assert_equal [true, true, true], [new_data.mask[0], new_data.mask[2], new_data.mask[4]]
  end

  # ---- hash lane (2026-07-07): object / fixlen coverage + first-occurrence ----

  def test_locate_addr_object_lane
    ref = CArray.object(4) { |i| ["a", "bb", "ccc", "dd"][i] }
    s   = CArray.object(3) { |i| ["ccc", "zz", "a"][i] }
    r = s.locate_addr(ref)
    assert_equal [2, nil, 0], [r[0], (r.mask[1] ? nil : r[1]), r[2]]
    assert_equal [false, true, false], r.mask.to_a   # "zz" absent -> masked
  end

  def test_locate_addr_fixlen_lane
    ref = CArray.fixlen(3, bytes: 2) { |i| ["ab", "cd", "ef"][i] }
    s   = CArray.fixlen(2, bytes: 2) { |i| ["ef", "xx"][i] }
    r = s.locate_addr(ref)
    assert_equal true, r.has_mask?
    assert_equal [false, true], r.mask.to_a
    assert_equal 2, r[0]                   # "ef" at ref addr 2
  end

  # On a ref with duplicate values, the hash lane returns the earliest
  # (appearance-order first) address, matching the discovery family.
  def test_locate_addr_duplicate_ref_first_occurrence
    ref = CA_INT([10, 20, 10, 30])
    r = CA_INT([10, 30]).locate_addr(ref)
    assert_equal [0, 3], r.to_a            # 10 -> first occurrence (addr 0)
    assert_equal false, r.has_mask?
  end

  # NaN collapses to one value across the family: a NaN query finds ref's NaN.
  def test_locate_addr_nan_collapse
    ref = CA_DOUBLE([1.0, Float::NAN, 3.0])
    r = CA_DOUBLE([Float::NAN, 3.0]).locate_addr(ref)
    assert_equal [1, 2], r.to_a
    assert_equal false, r.has_mask?
  end

  # A masked ref cell does not enter the map but still occupies its address,
  # so surviving values keep their true flat address.
  def test_locate_addr_masked_ref_cell
    ref = CA_INT([5, 6, 7]); ref[1] = UNDEF
    r = CA_INT([7, 6]).locate_addr(ref)
    assert_equal 2, r[0]                   # 7 at addr 2 (masked cell 1 still counted)
    assert_equal [false, true], r.mask.to_a       # masked ref value 6 is absent from map
  end

  # Regression: a length-1 (scalar-like) self must stay array-valued.
  # linear_section collapses a single-element query to a bare Float (or nil
  # out of range), which used to raise NoMethodError (mask_invalid on Float)
  # inside locate_nearest_addr.  Both locate_addr and locate_nearest_addr
  # must return a [1]-shaped CArray of ref addresses.
  def test_locate_addr_length1_self
    ref = CA_INT64((0..23).to_a)
    r = CA_INT64([5]).locate_addr(ref)
    assert_kind_of CArray, r
    assert_equal [1], r.shape
    assert_equal [5], r.to_a
    assert_equal false, r.has_mask?
  end

  def test_locate_nearest_addr_length1_self
    ref = CA_INT64((0..23).to_a)
    r = CA_INT64([5]).locate_nearest_addr(ref)
    assert_kind_of CArray, r
    assert_equal [1], r.shape
    assert_equal [5], r.to_a
    assert_equal false, r.has_mask?
  end

  # Length-1 self, rounding direction resolves the fractional index.
  def test_locate_nearest_addr_length1_directions
    ref = CA_INT64((0..23).to_a)
    assert_equal [5], CA_FLOAT64([5.4]).locate_nearest_addr(ref).to_a
    assert_equal [5], CA_FLOAT64([5.6]).locate_nearest_addr(ref, direction: :floor).to_a
    assert_equal [6], CA_FLOAT64([5.4]).locate_nearest_addr(ref, direction: :ceil).to_a
  end

  # Length-1 self outside the ref range propagates as a masked cell rather
  # than raising or collapsing to a scalar.
  def test_locate_nearest_addr_length1_oob_masks
    ref = CA_INT64((0..23).to_a)
    r = CA_INT64([99]).locate_nearest_addr(ref)
    assert_kind_of CArray, r
    assert_equal [1], r.shape
    assert_equal true, r.mask[0]
  end

  # Length-1 self with a tolerance too tight drops the match to UNDEF.
  def test_locate_nearest_addr_length1_tolerance
    ref = CA_FLOAT64([0.0, 10.0, 20.0, 30.0])
    kept = CA_FLOAT64([9.0]).locate_nearest_addr(ref, tolerance: 2.0)
    assert_equal [1], kept.to_a            # 9.0 -> addr 1 (dist 1 <= 2)
    dropped = CA_FLOAT64([9.0]).locate_nearest_addr(ref, tolerance: 0.5)
    assert_equal true, dropped.mask[0]     # dist 1 > 0.5 -> UNDEF
  end

  # 2-D self keeps its shape; addresses are flat into ref.
  def test_locate_addr_preserves_self_shape
    ref = CA_INT([100, 200, 300])
    s = CA_INT([[300, 100], [200, 999]])
    r = s.locate_addr(ref)
    assert_equal [2, 2], r.shape
    assert_equal 2, r[0, 0]
    assert_equal 0, r[0, 1]
    assert_equal 1, r[1, 0]
    assert_equal true, r.mask[1, 1]           # 999 absent
  end
end

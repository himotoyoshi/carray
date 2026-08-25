require "carray"
require "test/unit"

# Tests for CArray#project preserving Face identity (strip -> gather ->
# face-lift, 2026-07-08).  project is the length-preserving flat-address
# gather consumed by join gather / locate_nearest_addr; when self is a Face
# (CATime / CATimedelta / CACategorical) the result must come back as
# the same Face type with unit / labels carried and misses -> UNDEF.
class TestProjectFace < Test::Unit::TestCase

  def setup
    @addr = CA_INT32([2, 0, 0])
    @addr[1] = UNDEF                            # a miss -> UNDEF, length kept
  end

  def test_datetime_preserves_face_and_unit
    dt = CArray.time_series("2024-06-15", count: 3, unit: :h)
    r = dt.project(@addr)
    assert_equal CATime, r.class
    assert_equal 3, r.elements                  # length preserved
    assert_equal true, r.mask[1]                   # miss cell masked
    assert_equal dt[2].to_time, r[0].to_time    # gathered by address
    assert_equal dt[0].to_time, r[2].to_time
    assert_equal dt.unit, r.unit                # unit carried
  end

  def test_timedelta_preserves_face
    a = CArray.time_series("2024-06-15", count: 3, unit: :h)
    b = CArray.time_series("2024-06-14", count: 3, unit: :h)
    td = a - b
    r = td.project(@addr)
    assert_equal CATimedelta, r.class
    assert_equal 3, r.elements
    assert_equal true, r.mask[1]
    assert_equal td.unit, r.unit
  end

  def test_categorical_preserves_face_and_labels
    cat = CA_OBJECT(["x", "y", "z"]).categorize
    r = cat.project(@addr)
    assert_equal CACategorical, r.class
    assert_equal 3, r.elements
    assert_equal ["x", "y", "z"], r.labels      # vocabulary carried
    assert_equal true, r.mask[1]                   # miss -> UNDEF code = no category
    assert_equal [2, UNDEF, 0], r.codes.to_a    # gathered codes, miss masked
    assert_equal "z", r[0]
    assert_equal "x", r[2]
  end

  def test_non_face_unchanged
    num = CA_DOUBLE([10.0, 20.0, 30.0])
    r = num.project(@addr)
    assert_equal CArray, r.class
    assert_equal [30.0, UNDEF, 10.0], r.to_a

    obj = CA_OBJECT(["a", "b", "c"])
    ro = obj.project(@addr)
    assert_equal CArray, ro.class
    assert_equal ["c", UNDEF, "a"], ro.to_a
  end

  def test_non_face_fill_still_works
    num = CA_DOUBLE([10.0, 20.0, 30.0])
    oob = CA_INT32([-1, 1, 5])                  # lower / valid / upper
    assert_equal [-1.0, 20.0, 99.0], num.project(oob, -1.0, 99.0).to_a
    assert_equal [-1.0, 20.0, -1.0], num.project(oob, -1.0).to_a  # uval defaults to lval
    assert_equal [UNDEF, 20.0, UNDEF], num.project(oob).to_a      # no fill -> UNDEF
  end

  def test_datetime_fill_converts_via_write_hook
    # Fill args arrive as surface scalars; rb_ca_obj2ptr now fires the
    # scalar_to_storage write hook for a Face self, so out-of-range lval /
    # uval are converted to storage (self's unit) instead of being rejected.
    dt = CArray.time_series("2024-06-15", count: 4, unit: :h)  # 477336..339
    oob = CA_INT32([-1, 1, 5])                                  # lower / valid / upper
    r = dt.project(oob, dt[0], dt[3])
    assert_equal CATime, r.class
    assert_equal dt.unit, r.unit
    assert_equal [dt.parent[0], dt.parent[1], dt.parent[3]], r.parent.to_a
  end

  def test_categorical_fill_raises_no_write_hook
    # CACategorical is read-only and has no scalar_to_storage write hook
    # (label -> code encoding is a separate design, out of scope), so a fill
    # label has no storage conversion and raises loudly rather than
    # mis-storing.  The default UNDEF-at-miss path stays available.
    cat = CA_OBJECT(["x", "y", "z"]).categorize
    assert_raise(ArgumentError) { cat.project(@addr, "x", "z") }
  end

  def test_datetime_length_preservation_no_miss
    dt = CArray.time_series("2024-06-15", count: 4, unit: :h)
    addr = CA_INT32([3, 3, 1, 0])               # all in range, no mask
    r = dt.project(addr)
    assert_equal CATime, r.class
    assert_equal 4, r.elements
    assert_equal false, r.has_mask?             # unmask_copy path when no miss
    assert_equal dt[3].to_time, r[0].to_time
  end

end

require "carray"
require "test/unit"

# Tests for the Face surface-scalar -> storage WRITE dispatch
# (scalar_to_storage, 2026-07-08).  The read hook (storage_to_scalar) decodes
# a fetched cell to a surface Scalar; this write hook is its mirror, bringing
# a surface value object (Element / Time / DateTime) back into the Face's
# storage (self's unit) on store, so a fetched cell round-trips.
#
# unit :h, epoch = Unix, so 2024-06-15T02:00Z = 477338 hours.
class TestFaceWriteScalar < Test::Unit::TestCase

  def dt(freq = :h, periods = 4)
    CArray.time_series("2024-06-15", count: periods, unit: freq)
  end

  # ---- round-trip (the acceptance gate) ----

  def test_scalar_round_trip
    t = dt()
    t[0] = t[2]
    assert_equal t[2], t[0]
    assert_equal t.parent[2], t.parent[0]   # storage identity, same unit
  end

  def test_timedelta_round_trip
    d = (dt() - CArray.time_series("2024-06-14", count: 4, unit: :h))
    d[0] = d[3]
    assert_equal d[3], d[0]
    assert_equal d.parent[3], d.parent[0]
  end

  # ---- Time / DateTime bring their instant into self's unit ----

  def test_time_applies_unit
    t = dt()
    t[0] = Time.utc(2024, 6, 15, 2)         # was silently stored as raw seconds
    assert_equal 477338, t.parent[0]
    assert_equal Time.utc(2024, 6, 15, 2), t[0].to_time
  end

  def test_datetime_applies_unit
    require "date"
    t = dt()
    t[0] = DateTime.new(2024, 6, 15, 2, 0, 0, "+00:00")
    assert_equal 477338, t.parent[0]
  end

  # ---- cross-unit lossless reconciliation ----

  def test_cross_unit_lossless_finer_to_coarser
    hr = dt()
    sec = CArray.time_series("2024-06-15T02:00:00", count: 1, unit: :s)  # :s scalar
    hr[0] = sec[0]                          # :s -> :h, exact on the hour
    assert_equal 477338, hr.parent[0]
  end

  # ---- loud raises: unconvertible surface must never silently mis-store ----

  def test_non_exact_finer_to_coarser_raises
    hr = dt()
    off = CA_INT64([1718416860]).time(unit: :s)  # 02:01:00, not a whole hour
    assert_raise(ArgumentError) { hr[0] = off[0] }
  end

  def test_cross_group_calendar_write_widens
    # A time :M scalar HAS an instant, so storing it into a :D column
    # widens exactly (convert_instant!): 648 months = 2024-01 -> 2024-01-01.
    day = CArray.time_series("2024-06-15", count: 3, unit: :D)
    mon = CA_INT64([648]).time(unit: :M)
    day[0] = mon[0]
    assert_equal "2024-01-01", day[0].to_s
  end

  def test_cross_group_coarsen_write_off_boundary_raises
    # the coarsening direction: storing a mid-month :D scalar into a :M column
    # can't land on a month boundary, so it raises (no silent truncation).
    mon = CArray.int64(2) { |i| 648 + i }.time(unit: :M)  # 2024-01, 2024-02
    mid = CA_INT64([19750]).time(unit: :D)                # 2024-01-28
    assert_raise(ArgumentError) { mon[0] = mid[0] }
  end

  def test_timedelta_rejects_time
    d = CA_INT64([1, 2, 3]).timedelta(unit: :h)
    assert_raise(TypeError) { d[0] = Time.utc(2024, 1, 1) }  # Time is not a duration
  end

  # ---- bare Integer / String pass through unchanged ----

  def test_integer_is_raw_storage_escape
    t = dt()
    t[0] = 477338                           # the documented .parent escape
    assert_equal 477338, t.parent[0]
  end

  def test_string_not_silently_parsed
    t = dt()
    # String is out of scope for the write hook; behavior is unchanged from
    # the raw storage cast (a loud failure, not a silent parse).
    assert_raise(ArgumentError, TypeError) { t[0] = "2024-06-15T02:00Z" }
  end

  # ---- bulk store paths all fire the conversion ----

  def test_bulk_masked_scalar
    t = dt()
    src = t.parent.to_a                     # [477336, 477337, 477338, 477339]
    mask = CArray.boolean(4) {|i| [1, 0, 1, 0][i] }
    t[mask] = t[3]
    assert_equal [src[3], src[1], src[3], src[3]], t.parent.to_a
  end

  def test_bulk_range_scalar
    t = dt()
    src = t.parent.to_a                     # [477336, 477337, 477338, 477339]
    t[0..1] = t[3]
    assert_equal [src[3], src[3], src[2], src[3]], t.parent.to_a
  end

  def test_bulk_range_time_applies_unit
    t = dt()
    t[0..1] = Time.utc(2024, 6, 15, 3)      # 477339, unit applied (not raw seconds)
    assert_equal [477339, 477339], [t.parent[0], t.parent[1]]
  end

  def test_bulk_fill
    t = dt()
    t.fill(t[2])
    assert_equal [t.parent[2]] * 4, t.parent.to_a
  end

  def test_bulk_array_of_scalars
    t = dt()
    t[0..1] = [t[3], t[2]]                  # was TypeError (Scalar -> int64)
    assert_equal [t.parent[3], t.parent[2]], [t.parent[0], t.parent[1]]
  end

  def test_bulk_full_array_of_scalars
    t = dt()
    src = t.parent.to_a                     # [477336, 477337, 477338, 477339]
    t[] = [t[3], t[3], t[2], t[1]]
    assert_equal [src[3], src[3], src[2], src[1]], t.parent.to_a
  end

  # ---- CArray-to-CArray bulk store (6.2): a Face rvalue is reconciled to
  #      self's storage via to_comparable, so a same-Face bulk store becomes a
  #      storage xfer instead of raising DataTypeError (fixlen -> int64). ----

  def test_bulk_carray_same_unit
    t = dt()
    t[0..1] = t[1..2]                        # was DataTypeError (fixlen -> int64)
    assert_equal [477337, 477338, 477338, 477339], t.parent.to_a
  end

  def test_bulk_carray_cross_unit_exact
    ts = dt(:s)                              # seconds
    th = dt(:h)                              # hours
    ts[0..1] = th[1..2]                      # coarser -> finer is exact
    assert_equal 477337 * 3600, ts.parent[0]
    assert_equal 477338 * 3600, ts.parent[1]
  end

  def test_bulk_carray_cross_unit_non_exact_raises
    th = dt(:h)
    ts = dt(:s)
    # finer (:s) -> coarser (:h) with a non-whole remainder truncates; the
    # to_comparable algebra raises rather than silently mis-storing.
    assert_raise(ArgumentError) { th[0..1] = ts[1..2] }
  end

  def test_bulk_carray_cross_group_raises
    th = dt(:h)
    td = CATimedelta.wrap(CA_INT64([1, 2, 3, 4]), unit: :h)
    # time cannot reconcile a timedelta -> loud raise, no silent mis-store.
    assert_raise(TypeError) { th[0..1] = td[1..2] }
  end

  def test_bulk_carray_masked_rhs_propagates
    t   = dt()
    src = dt()
    src[1] = UNDEF
    t[0..1] = src[0..1]                      # mask must ride through .parent
    assert_equal [false, true, false, false], t.is_masked.to_a
    assert_equal src.parent[0], t.parent[0]
  end

  def test_bulk_carray_cross_unit_masked_rhs_propagates
    ts = dt(:s)
    th = dt(:h)
    th[1] = UNDEF
    ts[0..1] = th[1..2]                      # convert :h -> :s carrying the mask
    assert_equal [true, false, false], ts.is_masked[0..2].to_a
    assert_equal 477338 * 3600, ts.parent[1]
  end

  def test_bulk_plain_int64_carray_unchanged
    t = dt()
    t[0..1] = CA_INT64([100, 200])           # non-Face rvalue: raw storage store
    assert_equal [100, 200, 477338, 477339], t.parent.to_a
  end

  def test_bulk_plain_integer_carray_of_any_width_is_raw_storage
    t = dt()
    t[0..1] = CA_INT32([100, 200])
    assert_equal [100, 200, 477338, 477339], t.parent.to_a
  end

  def test_bulk_bare_non_integer_carray_refused
    # The raw-storage escape stays raw, but it has to be raw *storage*: the
    # scalar path refuses a bare Float rather than truncating it through the
    # storage cast, so the bulk path refuses a bare float array for the same
    # reason.  `.parent` is where the caller owns the cast.
    t = dt()
    assert_raise(TypeError) { t[0..1] = CA_FLOAT64([0.5, 1.9]) }
    assert_raise(TypeError) { t[0..1] = CA_OBJECT([1, 2]) }
    assert_equal [477336, 477337, 477338, 477339], t.parent.to_a   # untouched

    t.parent[0..1] = CA_FLOAT64([0.5, 1.9])   # explicit storage write: caller's cast
    assert_equal [0, 1, 477338, 477339], t.parent.to_a
  end

  # ---- UNDEF masking still works (not intercepted by the hook) ----

  def test_undef_still_masks
    t = dt()
    t[0] = UNDEF
    assert_equal true, t.is_masked[0]
    assert_equal UNDEF, t[0]
  end

  # ---- fetch still decodes to a Scalar (read hook intact after rename) ----

  def test_fetch_still_decodes_scalar
    t = dt()
    assert_kind_of CATime::Element, t[1]
  end
end

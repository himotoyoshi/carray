# Mask gap-fill: unmask / strip_mask with the method: keyword (hold / linear).
# See devel/PROPOSAL_UNMASK_FILL_METHOD.md.

require "carray"
require "carray/categorical"
require "test/unit" unless defined?(Test::Unit)

class TestMaskGapFillHold < Test::Unit::TestCase

  # ---- forward / backward hold -------------------------------------------

  def test_forward_copy
    a = CA_INT32([1, 0, 0, 4, 0]); a[1] = UNDEF; a[2] = UNDEF; a[4] = UNDEF
    c = a.strip_mask(method: :forward)
    assert_equal([1, 1, 1, 4, 4], c.to_a)
    refute(c.has_mask?)
    # source untouched (copy form)
    assert_equal([1, UNDEF, UNDEF, 4, UNDEF], a.to_a)
  end

  def test_forward_in_place_returns_self_and_mutates
    a = CA_INT32([1, 0, 0, 4]); a[1] = UNDEF; a[2] = UNDEF
    r = a.unmask(method: :forward)
    assert_same(a, r)
    assert_equal([1, 1, 1, 4], a.to_a)
    refute(a.any_masked?)
  end

  def test_backward
    a = CA_INT32([1, 0, 0, 4, 0]); a[1] = UNDEF; a[2] = UNDEF; a[4] = UNDEF
    c = a.strip_mask(method: :backward)
    assert_equal([1, 4, 4, 4, UNDEF], c.to_a)
    assert_equal([false, false, false, false, true], c.is_masked.to_a)
  end

  def test_ffill_bfill_aliases
    a = CA_INT32([1, 0, 3]); a[1] = UNDEF
    assert_equal(a.strip_mask(method: :forward).to_a,
                 a.strip_mask(method: :ffill).to_a)
    assert_equal(a.strip_mask(method: :backward).to_a,
                 a.strip_mask(method: :bfill).to_a)
  end

  def test_leading_masked_stays_masked_forward
    a = CA_INT32([0, 0, 3, 0, 5]); a[0] = UNDEF; a[1] = UNDEF; a[3] = UNDEF
    c = a.strip_mask(method: :forward)
    assert_equal([UNDEF, UNDEF, 3, 3, 5], c.to_a)
    assert_equal([true, true, false, false, false], c.is_masked.to_a)
  end

  def test_trailing_masked_stays_masked_backward
    a = CA_INT32([1, 0, 3, 0, 0]); a[1] = UNDEF; a[3] = UNDEF; a[4] = UNDEF
    c = a.strip_mask(method: :backward)
    assert_equal([1, 3, 3, UNDEF, UNDEF], c.to_a)
    assert_equal([false, false, false, true, true], c.is_masked.to_a)
  end

  def test_all_masked_stays_all_masked
    a = CA_INT32([0, 0, 0]); a[] = UNDEF
    c = a.strip_mask(method: :forward)
    assert_equal([true, true, true], c.is_masked.to_a)
  end

  def test_no_mask_is_noop_copy
    a = CA_INT32([1, 2, 3])
    c = a.strip_mask(method: :forward)
    assert_equal([1, 2, 3], c.to_a)
    refute(c.has_mask?)
  end

  def test_fully_filled_in_place_drops_mask_like_constant_unmask
    a = CA_INT32([1, 0, 0, 4]); a[1] = UNDEF; a[2] = UNDEF
    a.unmask(method: :forward)
    refute(a.any_masked?)
  end

  def test_residual_in_place_keeps_reduced_mask
    a = CA_INT32([0, 0, 3]); a[0] = UNDEF; a[1] = UNDEF
    a.unmask(method: :forward)
    assert_equal([UNDEF, UNDEF, 3], a.to_a)
    assert_equal([true, true, false], a.is_masked.to_a)
  end

  # ---- per-axis + flatten -------------------------------------------------

  def test_per_axis_1
    m = CA_INT32([[1, 0, 3], [0, 5, 0]])
    m[0, 1] = UNDEF; m[1, 0] = UNDEF; m[1, 2] = UNDEF
    c = m.strip_mask(method: :forward, axis: 1)
    assert_equal([[1, 1, 3], [UNDEF, 5, 5]], c.to_a)
  end

  def test_per_axis_0
    m = CA_INT32([[1, 0, 3], [0, 5, 0]])
    m[0, 1] = UNDEF; m[1, 0] = UNDEF; m[1, 2] = UNDEF
    c = m.strip_mask(method: :forward, axis: 0)
    assert_equal([[1, UNDEF, 3], [1, 5, 3]], c.to_a)
  end

  def test_flatten_default_is_row_major
    m = CA_INT32([[1, 0], [0, 4]]); m[0, 1] = UNDEF; m[1, 0] = UNDEF
    c = m.strip_mask(method: :forward)      # flatten -> [1, U, U, 4] -> [1,1,1,4]
    assert_equal([[1, 1], [1, 4]], c.to_a)
  end

  def test_negative_axis
    m = CA_INT32([[1, 0, 3]]); m[0, 1] = UNDEF
    assert_equal(m.strip_mask(method: :forward, axis: 1).to_a,
                 m.strip_mask(method: :forward, axis: -1).to_a)
  end

  # ---- dtype coverage -----------------------------------------------------

  def test_float_hold
    a = CA_FLOAT64([1.5, 0, 0, 4.5]); a[1] = UNDEF; a[2] = UNDEF
    assert_equal([1.5, 1.5, 1.5, 4.5], a.strip_mask(method: :forward).to_a)
  end

  def test_uint_dtypes_hold
    [:int8, :int16, :int64, :uint8, :uint16, :uint32].each do |t|
      a = CArray.send(t, 4).seq
      a[1] = UNDEF; a[2] = UNDEF
      c = a.strip_mask(method: :forward)
      assert_equal([0, 0, 0, 3], c.to_a, "data_type #{t}")
    end
  end

  def test_bool_hold
    a = CArray.boolean(4) { |i| i.even? }; a[1] = UNDEF; a[2] = UNDEF
    assert_equal([true, true, true, false], a.strip_mask(method: :forward).to_a)
  end

  def test_complex_hold
    a = CA_CMPLX128([Complex(1, 1), 0, 0, Complex(4, 4)])
    a[1] = UNDEF; a[2] = UNDEF
    assert_equal([Complex(1, 1), Complex(1, 1), Complex(1, 1), Complex(4, 4)],
                 a.strip_mask(method: :forward).to_a)
  end

  def test_object_hold
    a = CA_OBJECT(["x", nil, "z", nil]); a[1] = UNDEF; a[3] = UNDEF
    assert_equal(["x", "x", "z", "z"], a.strip_mask(method: :forward).to_a)
  end

  def test_fixlen_hold
    a = CArray.fixlen(3, bytes: 3) { |i| ["aaa", "bbb", "ccc"][i] }
    a[1] = UNDEF
    assert_equal(["aaa", "aaa", "ccc"], a.strip_mask(method: :forward).to_a)
  end

  def test_datetime_face_hold_carries_storage_and_relifts
    t = CArray.time_series("2020-01-01", count: 4, unit: :D)
    t[1] = UNDEF; t[2] = UNDEF
    c = t.strip_mask(method: :forward)
    assert_equal(CATime, c.class)
    assert_equal([t[0].to_time, t[0].to_time, t[0].to_time, t[3].to_time],
                 c.to_a.map(&:to_time))
  end

  def test_categorical_face_hold
    keys = CArray.object(4) { |i| %w[a b c a][i] }
    keys[1] = UNDEF; keys[2] = UNDEF
    cat = keys.categorize
    c = cat.strip_mask(method: :forward)
    assert_equal(CACategorical, c.class)
    assert_equal(["a", "a", "a", "a"], c.to_a)
  end

  def test_face_hold_in_place
    # The in-place form writes through the Face's storage: a bulk store into
    # its fixlen surface would try to cast the int64 ticks to it.
    t = CArray.time_series("2020-01-01", count: 4, unit: :D)
    t[1] = UNDEF; t[2] = UNDEF
    f = t.copy
    f.unmask(method: :forward)
    assert_equal(CATime, f.class)
    assert_equal(t.unit, f.unit)
    assert_equal([0, 0, 0, 3].map { |i| t.parent[i] }, f.parent.to_a)
    assert_equal(0, f.count_masked)
    b = t.copy
    b.unmask(method: :backward)
    assert_equal([0, 3, 3, 3].map { |i| t.parent[i] }, b.parent.to_a)
  end

  def test_face_hold_leading_run_stays_masked
    # A leading masked run has no value to carry, so hold marks the output
    # cell UNDEF.  That path indexes the output mask off the raw buffer, which
    # needs the storage entity rather than a re-wrapped Face (it used to
    # segfault on the Face's unattached view).
    t = CArray.time_series("2020-01-01", count: 3, unit: :D)
    t[0] = UNDEF
    c = t.strip_mask(method: :forward)
    assert_equal(CATime, c.class)
    assert_equal([true, false, false], c.is_masked.to_a)
    assert_equal(t.parent[1], c.parent[1])
  end

  # ---- linear -------------------------------------------------------------

  def test_linear_flatten
    v = CA_FLOAT64([1.0, 0, 0, 4.0, 0]); v[1] = UNDEF; v[2] = UNDEF; v[4] = UNDEF
    c = v.strip_mask(method: :linear)
    assert_equal([1.0, 2.0, 3.0, 4.0, UNDEF], c.to_a)
    assert_equal([false, false, false, false, true], c.is_masked.to_a)
  end

  def test_linear_unequal_spacing
    # valid only at index 0 and 4: fill the 3 interior cells linearly.
    v = CA_FLOAT64([0.0, 0, 0, 0, 8.0])
    v[1] = UNDEF; v[2] = UNDEF; v[3] = UNDEF
    assert_equal([0.0, 2.0, 4.0, 6.0, 8.0], v.strip_mask(method: :linear).to_a)
  end

  def test_linear_preserves_integer_dtype
    v = CA_INT32([0, 0, 0, 0, 8]); v[1] = UNDEF; v[2] = UNDEF; v[3] = UNDEF
    c = v.strip_mask(method: :linear)
    assert_equal(CA_INT32, c.data_type)
    assert_equal([0, 2, 4, 6, 8], c.to_a)
  end

  def test_linear_leading_trailing_stay_masked
    v = CA_FLOAT64([0, 1.0, 0, 3.0, 0]); v[0] = UNDEF; v[2] = UNDEF; v[4] = UNDEF
    c = v.strip_mask(method: :linear)
    assert_equal([UNDEF, 1.0, 2.0, 3.0, UNDEF], c.to_a)
  end

  def test_linear_per_axis
    m = CA_FLOAT64([[1.0, 0, 0, 4.0], [10.0, 0, 30.0, 0]])
    m[0, 1] = UNDEF; m[0, 2] = UNDEF; m[1, 1] = UNDEF; m[1, 3] = UNDEF
    c = m.strip_mask(method: :linear, axis: 1)
    assert_equal([[1.0, 2.0, 3.0, 4.0], [10.0, 20.0, 30.0, UNDEF]], c.to_a)
  end

  def test_linear_fewer_than_two_valid_points_stays_masked
    v = CA_FLOAT64([0, 5.0, 0]); v[0] = UNDEF; v[2] = UNDEF
    c = v.strip_mask(method: :linear)
    assert_equal([UNDEF, 5.0, UNDEF], c.to_a)
    z = CA_FLOAT64([0, 0]); z[] = UNDEF
    assert_equal([true, true], z.strip_mask(method: :linear).is_masked.to_a)
  end

  def test_linear_per_axis_fiber_with_too_few_points
    m = CA_FLOAT64([[1.0, 0, 3.0], [0, 0, 0]])
    m[0, 1] = UNDEF; m[1, 0] = UNDEF; m[1, 1] = UNDEF; m[1, 2] = UNDEF
    c = m.strip_mask(method: :linear, axis: 1)
    assert_equal([[1.0, 2.0, 3.0], [UNDEF, UNDEF, UNDEF]], c.to_a)
  end

  def test_linear_rejects_non_numeric
    a = CA_OBJECT(["x", nil]); a[1] = UNDEF
    assert_raise(ArgumentError) { a.strip_mask(method: :linear) }
  end

  # ---- linear on a time Face ---------------------------------------------

  def test_linear_on_time_face_keeps_the_unit
    # A Face interpolates through its own linear_fetch, so the result stays on
    # the array's grid (rounded to it) instead of becoming raw float ticks.
    t = CArray.time_series("2020-01-01", count: 4, unit: :D)
    t[1] = UNDEF; t[2] = UNDEF
    c = t.strip_mask(method: :linear)
    assert_equal(CATime, c.class)
    assert_equal(t.unit, c.unit)
    assert_equal([0, 1, 2, 3].map { |i| t.parent[0] + i }, c.parent.to_a)
    f = t.copy
    f.unmask(method: :linear)
    assert_equal(c.parent.to_a, f.parent.to_a)
  end

  def test_linear_on_time_face_leaves_the_exterior_masked
    t = CArray.time_series("2020-01-01", count: 4, unit: :D)
    t[0] = UNDEF; t[3] = UNDEF
    c = t.strip_mask(method: :linear)
    assert_equal([true, false, false, true], c.is_masked.to_a)
  end

  def test_linear_on_time_face_per_axis
    m = CArray.int64(2, 4) { |i, j| 19723 + i * 10 + j }.time(unit: :D)
    m[0, 1] = UNDEF
    m[1, 2] = UNDEF
    c = m.strip_mask(method: :linear, axis: 1)
    assert_equal(CATime, c.class)
    assert_equal(m.unit, c.unit)
    assert_equal([[19723, 19724, 19725, 19726],
                  [19733, 19734, 19735, 19736]], c.parent.to_a)
  end

  def test_linear_on_timedelta_face
    td = CArray.int64(3) { |i| [1, 0, 7][i] }.timedelta(unit: :D)
    td[1] = UNDEF
    c = td.strip_mask(method: :linear)
    assert_equal(CATimedelta, c.class)
    assert_equal([1, 4, 7], c.parent.to_a)
  end

  def test_linear_on_a_non_orderable_face_raises_from_the_face
    # The gate lets any Face through and the Face itself decides: a categorical
    # is not ORDERABLE, so interpolating its codes is refused there.
    keys = CArray.object(3) { |i| %w[a b c][i] }
    cat = keys.categorize.copy
    cat.parent[1] = UNDEF
    assert_raise(ArgumentError) { cat.strip_mask(method: :linear) }
  end

  # ---- guards / errors ----------------------------------------------------

  def test_mutual_exclusion_unmask
    a = CA_INT32([1, 0, 3]); a[1] = UNDEF
    assert_raise(ArgumentError) { a.unmask(9, method: :forward) }
  end

  def test_mutual_exclusion_strip_mask
    a = CA_INT32([1, 0, 3]); a[1] = UNDEF
    assert_raise(ArgumentError) { a.strip_mask(9, method: :forward) }
  end

  def test_unknown_method_raises
    a = CA_INT32([1, 0, 3]); a[1] = UNDEF
    assert_raise(ArgumentError) { a.strip_mask(method: :bogus) }
    assert_raise(ArgumentError) { a.unmask(method: :bogus) }
  end

  def test_axis_out_of_range_raises
    a = CA_INT32([1, 0, 3]); a[1] = UNDEF
    assert_raise(ArgumentError) { a.strip_mask(method: :forward, axis: 5) }
  end

  # ---- constant path unchanged -------------------------------------------

  def test_constant_positional_still_works
    a = CA_INT32([1, 0, 3]); a[1] = UNDEF
    assert_equal([1, -1, 3], a.strip_mask(-1).to_a)
    b = a.copy; b.unmask(-1)
    assert_equal([1, -1, 3], b.to_a)
  end

  def test_symbol_constant_fill_not_taken_as_method
    a = CA_OBJECT(["x", nil]); a[1] = UNDEF
    assert_equal(["x", :na], a.strip_mask(:na).to_a)
  end

  def test_strip_mask_no_arg_still_raises
    a = CA_FLOAT64([1.0, 0]); a[1] = UNDEF
    assert_raise(ArgumentError) { a.strip_mask }
  end

  def test_unmask_no_arg_clears_mask
    a = CA_INT32([1, 0, 3]); a[1] = UNDEF
    a.unmask
    refute(a.any_masked?)
  end
end

# Test for the integer path of CArray#__mask_duplicates__ (the single-pass
# seen-set behind CArray#mask_duplicates for numeric payloads) and the
# mask_duplicates integration that dispatches to it. Float cases live in
# test_mask_duplicates_float.rb.
#
# Contract: for an integer payload the fast seen-set path must produce EXACTLY
# the same mask_duplicates result as the sort-based path it replaces, across
# signedness, width, masks, negatives, high cardinality, flatten + per-axis, and
# multi-dim shapes. The reference below reproduces the old sort-based backend so
# the fast path is checked against the behaviour it replaces.

require "test/unit"
require "carray"

class TestMaskDuplicatesInt < Test::Unit::TestCase

  # The pre-fast-path numeric backend: sort_addr -> gather -> uniq_scan ->
  # scatter, reproduced here (independent of dtype gate) as the oracle.
  def reference_dup (a, k)
    vals   = a.value
    addrs  = vals.sort_addr(axis: k)
    sorted = a[addrs]
    sorted_dup = sorted.uniq_scan_ki(axis: k)
    dup = CArray.boolean(*a.shape).fill(0)
    dup[addrs] = sorted_dup
    dup
  end

  # Compare the whole mask_duplicates result (mask positions + surviving values)
  # against the reference, for both flatten and every per-axis form.
  def assert_mask_dup_matches (a, msg)
    # flatten form
    got_flat = a.mask_duplicates
    ref_flat_dup = reference_dup(a.flatten, 0).reshape(*a.shape)
    ref_flat = a.mask_where(ref_flat_dup)
    assert_equal ref_flat.is_masked.to_a, got_flat.is_masked.to_a,
                 "#{msg}: flatten mask positions"
    assert_equal ref_flat.value.to_a, got_flat.value.to_a,
                 "#{msg}: flatten surviving values"

    # per-axis forms
    a.ndim.times do |k|
      got = a.mask_duplicates(axis: k)
      ref = a.mask_where(reference_dup(a, k))
      assert_equal ref.is_masked.to_a, got.is_masked.to_a,
                   "#{msg}: axis #{k} mask positions"
      assert_equal ref.value.to_a, got.value.to_a,
                   "#{msg}: axis #{k} surviving values"
    end
  end

  def test_appearance_int32
    assert_mask_dup_matches(CArray.int32(8) { |i| [3, 1, 3, 7, 1, 3, 7, 1][i] },
                            "int32 flat")
  end

  def test_negative_values
    assert_mask_dup_matches(CArray.int32(6) { |i| [-5, 2, -5, 0, 2, -5][i] },
                            "negatives")
  end

  def test_unsigned_uint16
    assert_mask_dup_matches(CArray.uint16(5) { |i| [40000, 1, 40000, 65535, 1][i] },
                            "uint16")
  end

  def test_all_int_dtypes
    src = [3, 1, 3, 7, 1, 3, 7, 1, 5, 5]
    [CA_INT8, CA_INT16, CA_INT32, CA_INT64,
     CA_UINT8, CA_UINT16, CA_UINT32, CA_UINT64].each do |dt|
      a = CArray.new(dt, [src.size]) { |i| src[i] }
      assert_mask_dup_matches(a, "dtype #{dt}")
    end
  end

  def test_uint64_above_int64_max
    big = 18446744073709551615
    a = CArray.uint64(4) { |i| [big, 1, big, 1][i] }
    got = a.mask_duplicates
    assert_equal [false, false, true, true], got.is_masked.to_a
  end

  def test_masked_cells_excluded
    a = CArray.int32(6) { |i| [3, 1, 3, 7, 1, 3][i] }
    a[1] = UNDEF
    a[4] = UNDEF
    assert_mask_dup_matches(a, "masked flat")
  end

  def test_masked_cells_stay_masked_not_marked
    # Masked cells do not participate and are not marked; they remain masked
    # from their original mask, and every unmasked duplicate is marked.
    a = CArray.int32(7) { |i| [5, 5, 9, 5, 9, 9, 2][i] }
    a[0] = UNDEF   # first 5 masked; the next 5 becomes the first *seen* 5
    got = a.mask_duplicates
    # index0 masked; 5@1 first-seen, 9@2 first-seen, 5@3 dup, 9@4 dup, 9@5 dup, 2@6 first-seen
    assert_equal [true, false, false, true, true, true, false], got.is_masked.to_a
  end

  def test_multi_dim_flatten_and_per_axis
    a = CArray.int64(3, 4) { |i, j| (i * 4 + j) % 5 }
    assert_mask_dup_matches(a, "3x4")
  end

  def test_multi_dim_3d
    a = CArray.int32(2, 3, 4) { |i, j, k| (i * 12 + j * 4 + k) % 6 }
    assert_mask_dup_matches(a, "2x3x4")
  end

  def test_high_cardinality_grows_hash
    # Forces several hash grows within a single fiber.
    a = CArray.int32(5000) { |i| i % 3000 }
    assert_mask_dup_matches(a, "high cardinality")
  end

  def test_per_axis_independent_fibers
    # Each row is an independent seen-set: a value repeated across rows is not a
    # duplicate, only a repeat within its own fiber is.
    a = CArray.int32(2, 3) { |i, j| [[1, 1, 2], [1, 2, 3]][i][j] }
    got = a.mask_duplicates(axis: 1)
    assert_equal [[false, true, false], [false, false, false]], got.is_masked.to_a
  end

  def test_single_element
    assert_mask_dup_matches(CArray.int32(1) { 9 }, "single element")
  end

  def test_all_same
    assert_mask_dup_matches(CArray.int32(5) { 7 }, "all same")
  end

  def test_all_distinct
    assert_mask_dup_matches(CArray.int32(6) { |i| i }, "all distinct")
  end

  def test_boolean_not_routed_to_int_path
    # boolean rides the uint8 lane of the seen-set hash (__mask_duplicates__),
    # the same appearance-order path every other dtype uses: first true and
    # first false are kept, later occurrences are masked.
    a = CArray.boolean(5) { |i| [true, false, true, true, false][i] }
    out = a.mask_duplicates
    # bulk to_a on boolean yields Integer 0/1; masked cells are UNDEF
    assert_equal([true, false, UNDEF, UNDEF, UNDEF], out.to_a)
    assert_equal([false, false, true, true, true], out.is_masked.to_a)   # is_masked is boolean 0/1
  end

  def test_boolean_per_axis_and_masked
    # per-axis boolean duplicates, independent per fiber
    m = CArray.boolean(2, 4) { |i, j| [[1, 1, 0, 0], [0, 1, 1, 0]][i][j] }
    out = m.mask_duplicates(axis: 1)
    assert_equal([[false, true, false, true],
                  [false, false, true, true]], out.is_masked.to_a)

    # pre-masked cells stay masked and do not participate in judging
    mk = CArray.boolean(5) { |i| [1, 0, 1, 1, 0][i] }
    mk[2] = UNDEF
    assert_equal([false, false, true, true, true], mk.mask_duplicates.is_masked.to_a)
  end
end

# Test for CArray#__factorize_appearance__ (the single-pass factorization behind
# CArray#categorize) and the categorize integration that dispatches to it.
#
# Contract: with automatic (labels: nil) appearance-order vocabulary and
# sort_labels: false, categorize routes the integer / float / object / fixlen
# lanes through the one-pass factorizer. For lanes/values where the hash-key
# distinctness agrees with the old discovery path (integer, plain float, plain
# strings/fixlen) the codes + levels + mask are identical, pinned here against a
# reproduced discovery reference. Three cases diverge deliberately, aligning
# categorize with the value-hash family's distinctness: Float NaN collapses to a
# single category (the old path dropped NaN cells to masked), -0.0 == +0.0, and
# mixed Integer / Float object keys stay distinct via eql? (1 and 1.0 separate).

require "test/unit"
require "carray"

class TestFactorizeAppearance < Test::Unit::TestCase

  # Reference discovery: the pre-factorize categorize path (mask_duplicates +
  # per-label masked write), reproduced here so the fast path is checked against
  # the behaviour it replaces.
  def reference (a)
    labels = a.mask_duplicates[:is_not_masked].to_a
    k = labels.size
    ct, sent =
      if    k <= 0xFF   then [CA_UINT8,  0xFF]
      elsif k <= 0xFFFF then [CA_UINT16, 0xFFFF]
      else                   [CA_UINT32, 0xFFFFFFFF]
      end
    codes = CArray.new(ct, a.shape).fill(sent)
    labels.each_with_index { |l, c| codes[a.eq(l)] = c }
    [codes, labels]
  end

  def assert_categorize_matches (a, msg)
    cat = a.categorize
    ref_codes, ref_labels = reference(a)

    assert_equal ref_labels, cat.labels, "#{msg}: labels (appearance order)"
    assert_equal a.is_masked.to_a, cat.codes.is_masked.to_a, "#{msg}: mask positions"

    # Every non-masked cell must decode to the same value through both vocabs.
    fl = cat.labels
    a.elements.times do |i|
      next if a.is_masked[i]
      assert_equal ref_labels[ref_codes[i]], fl[cat.codes[i]], "#{msg}: cell #{i}"
    end
  end

  def test_appearance_order
    assert_categorize_matches(CArray.int32(8) { |i| [3, 1, 3, 7, 1, 3, 7, 1][i] },
                              "appearance int32")
  end

  def test_negative_values
    assert_categorize_matches(CArray.int32(6) { |i| [-5, 2, -5, 0, 2, -5][i] },
                              "negatives")
  end

  def test_unsigned
    assert_categorize_matches(CArray.uint16(5) { |i| [40000, 1, 40000, 65535, 1][i] },
                              "uint16")
  end

  def test_masked_cells_excluded
    a = CArray.int32(6) { |i| [3, 1, 3, 7, 1, 3][i] }
    a[1] = UNDEF
    a[4] = UNDEF
    assert_categorize_matches(a, "masked")
  end

  def test_multi_dim_row_major_order
    assert_categorize_matches(CArray.int64(3, 4) { |i, j| (i * 4 + j) % 5 },
                              "multi_dim")
  end

  def test_narrowing_uint8_to_uint16_boundary
    # k = 300 crosses the uint8 (<=255) -> uint16 storage boundary.
    a = CArray.int32(1000) { |i| i % 300 }
    assert_equal CA_UINT16, a.categorize.codes.data_type
    assert_categorize_matches(a, "k=300 uint16")
  end

  def test_narrowing_uint16_to_uint32_boundary
    # k = 70000 crosses the uint16 (<=65535) -> uint32 storage boundary.
    a = CArray.int32(70000) { |i| i % 70000 }
    assert_equal CA_UINT32, a.categorize.codes.data_type
    assert_categorize_matches(a, "k=70000 uint32")
  end

  def test_single_group
    assert_categorize_matches(CArray.int32(2) { |i| [9, 9][i] }, "single group")
  end

  def test_uint64_above_int64_max
    # A bitwise-widened key preserves equality for uint64 values that the old
    # eq-based path could not even compare (bignum > INT64_MAX).
    big = 18446744073709551615
    a = CArray.uint64(4) { |i| [big, 1, big, 1][i] }
    cat = a.categorize
    assert_equal [big, 1], cat.labels
    assert_equal [0, 1, 0, 1], cat.codes.to_a
  end

  def test_storage_dtype_is_narrow
    assert_equal CA_UINT8, (CArray.int32(10) { |i| i % 4 }).categorize.codes.data_type
  end

  def test_boolean_bypasses_integer_factorizer
    # boolean is not integer?, so categorize must not route it to the integer
    # factorizer (which would raise "integer dtype required"). It takes the
    # sort-based discovery path (sort_addr + uniq_scan) instead; now that
    # boolean is a full sort/order citizen, that path is functional.
    a = CArray.boolean(4) { |i| i.even? }   # [true, false, true, false]
    cat = a.categorize
    assert_equal [0, 1, 0, 1], cat.codes.to_a
    assert_equal [true, false], cat.labels          # first-appearance order: true, false
  end

  def test_sort_labels_still_works
    a = CArray.int32(6) { |i| [3, 1, 3, 7, 1, 3][i] }
    cat = a.categorize(sort_labels: true)
    assert_equal [1, 3, 7], cat.labels
  end

  # --- lanes that agree with the discovery path (equivalence pinned) ----------

  def test_object_strings
    a = CA_OBJECT(%w[east west east north west east])
    assert_categorize_matches(a, "object strings")
    assert_equal %w[east west north], a.categorize.labels
    assert_equal [0, 1, 0, 2, 1, 0], a.categorize.codes.to_a
  end

  def test_fixlen
    a = CArray.new(CA_FIXLEN, [5], bytes: 3)
    %w[abc xy abc pq xy].each_with_index { |s, i| a[i] = s }
    assert_categorize_matches(a, "fixlen")
    assert_equal [0, 1, 0, 2, 1], a.categorize.codes.to_a
  end

  def test_object_masked_excluded
    a = CA_OBJECT(%w[a b a c b])
    a[1] = UNDEF
    a[4] = UNDEF
    cat = a.categorize
    assert_equal [false, true, false, false, true], cat.codes.is_masked.to_a
    assert_equal %w[a c], cat.labels
  end

  def test_float_plain_matches_discovery
    a = CA_DOUBLE([1.5, 2.5, 1.5, 3.5, 2.5])
    assert_categorize_matches(a, "plain float")
    assert_equal [0, 1, 0, 2, 1], a.categorize.codes.to_a
  end

  # --- deliberate divergences from the old discovery path ---------------------

  def test_float_nan_collapses_to_one_category
    # The old discovery path dropped NaN cells (eq(NaN) matched nothing -> masked).
    # The factorizer collapses every NaN to a single real category.
    nan = 0.0 / 0.0
    a = CA_DOUBLE([1.0, nan, 2.0, nan, 1.0])
    cat = a.categorize
    assert_equal [false, false, false, false, false], cat.codes.is_masked.to_a, "NaN cells are not masked"
    assert_equal cat.codes[1], cat.codes[3], "both NaN share one category"
    assert_equal 3, cat.labels.size
    assert cat.labels.any? { |l| l.is_a?(Float) && l.nan? }, "a NaN level exists"
  end

  def test_object_nan_values_collapse
    nan = 0.0 / 0.0
    a = CA_OBJECT(["x", nan, "y", nan])
    cat = a.categorize
    assert_equal cat.codes[1], cat.codes[3], "both NaN VALUEs share one category"
    assert_equal 3, cat.labels.size
  end

  def test_negative_zero_folds_with_positive_zero
    a = CA_DOUBLE([-0.0, 0.0, 1.0, -0.0])
    cat = a.categorize
    assert_equal cat.codes[0], cat.codes[1], "-0.0 and +0.0 share one category"
    assert_equal 2, cat.labels.size
  end

  def test_object_mixed_int_float_stay_distinct
    # eql? (not ==) keys the object lane, so 1 (Integer) and 1.0 (Float) are
    # separate categories -- the discovery levels already separated them.
    a = CA_OBJECT([1, 1.0, 1, 1.0])
    cat = a.categorize
    assert_equal [0, 1, 0, 1], cat.codes.to_a
    assert_equal 2, cat.labels.size
  end
end

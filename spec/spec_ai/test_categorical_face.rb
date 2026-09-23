# test_categorical_face.rb — CACategorical (READONLY codes-as-storage Face)
#
# CACategorical is a categorical dtype: dense integer codes (the storage
# parent) + a label vocabulary, structurally the same as a pandas Categorical
# / Arrow dictionary. It is a READONLY Face over the codes, so per-cell access
# decodes code -> label, codes ride the view chain, and numeric kernels are
# gated. Exclusion is encoded both as a mask AND as the all-ones sentinel value
# (type-max for unsigned codes, -1 for signed); READONLY keeps them in sync.

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../ext", __dir__)

require "carray"
require "carray/categorical"
require "test/unit"

class TestCACategoricalFace < Test::Unit::TestCase

  # ---- from_codes (the pandas / Arrow import receiver) --------------------

  def test_from_codes_basic
    codes = CArray.uint8(6) { |i| [0, 1, 0, 2, 1, 0][i] }
    cat   = CACategorical.from_codes(codes, ["tokyo", "osaka", "kyoto"])

    assert_kind_of(CACategorical, cat)
    assert_kind_of(CArray, cat)
    assert_true(cat.face?)
    assert_equal(["tokyo", "osaka", "kyoto"], cat.labels)
    assert_equal(3, cat.labels.size)          # category count = labels.size
  end

  def test_from_codes_element_decodes_to_label
    codes = CArray.uint8(6) { |i| [0, 1, 0, 2, 1, 0][i] }
    cat   = CACategorical.from_codes(codes, ["tokyo", "osaka", "kyoto"])

    assert_equal("tokyo", cat[0])
    assert_equal("kyoto", cat[3])
    assert_equal(["tokyo", "osaka", "tokyo", "kyoto", "osaka", "tokyo"], cat.to_a)
  end

  def test_codes_is_the_storage_parent
    codes = CArray.uint8(6) { |i| [0, 1, 0, 2, 1, 0][i] }
    cat   = CACategorical.from_codes(codes, ["tokyo", "osaka", "kyoto"])

    assert_equal([0, 1, 0, 2, 1, 0], cat.codes.to_a)
    assert_equal(cat.parent, cat.codes)
  end

  def test_from_codes_rejects_non_integer_codes
    assert_raise(ArgumentError) {
      CACategorical.from_codes(CArray.float64(3), ["a", "b", "c"])
    }
  end

  # ---- from_codes validates and normalises what it receives ---------------
  #
  # from_codes is the one door an already-built encoding comes through, so it
  # is the only place that can still check it — #initialize marks the codes
  # read-only on the next line. The exclusion sentinel and the mask have
  # different readers (the axis-group kernel classifies on the code byte, the
  # materialising paths classify on the mask), so a categorical that carries
  # only one of them answers membership two ways with nothing raised.

  def test_from_codes_writes_the_sentinel_into_a_cell_that_arrived_masked
    # An Arrow dictionary carries missingness in a validity bitmap with
    # arbitrary code bytes — frequently a valid-looking 0 — so masked-only
    # input is the ordinary import, not an edge case.
    codes = CArray.uint8(4) { |i| [0, 1, 0, 1][i] }
    codes[1] = UNDEF
    cat = CACategorical.from_codes(codes, ["a", "b"])

    assert_equal([false, true, false, false], cat.is_masked.to_a)
    assert_equal([0, 255, 0, 1], cat.codes.value.to_a)   # sentinel, not the stale 1
    # the documented byte-reinterpret export reads -1 at an excluded cell
    assert_equal([0, -1, 0, 1],
                 cat.codes.value.refer(CA_INT8, cat.codes.shape).to_a)
  end

  def test_from_codes_leaves_the_two_encodings_agreeing_for_every_reader
    codes = CArray.uint8(4) { |i| [0, 1, 0, 1][i] }
    codes.mask = CA_BOOLEAN([0, 0, 1, 0])
    cat = CACategorical.from_codes(codes, ["a", "b"])
    v = CArray.float64(4).seq!(1)
    g = v.axis_group(cat)

    # the byte reader (scatter kernel) and the mask reader (materialise) agree
    assert_equal([1.0, 6.0], v[g].sum(axis: :group).to_a)
    assert_equal([1, 2],     v[g].count(axis: :group).to_a)
    assert_equal([1.0, 6.0], v.group_by_category(cat).sum.to_a)
    assert_equal([1.0, 2.0, UNDEF, 6.0], v[g].cumsum(axis: :group).to_a)
  end

  def test_from_codes_refuses_a_vocabulary_too_large_for_the_codes_type
    labels = (0...256).map { |i| "L#{i}" }
    # uint8 spends its top value on the sentinel, so 255 labels is the limit
    assert_raise(ArgumentError) {
      CACategorical.from_codes(CArray.uint8(3) { |i| [0, 255, 1][i] }, labels)
    }
    # the boundary itself is fine, on both signs, and a wider type takes 256
    assert_equal(["L0", "L254"],
                 CACategorical.from_codes(CArray.uint8(2) { |i| [0, 254][i] },
                                          labels[0, 255]).to_a)
    assert_equal(["L0", "L127"],
                 CACategorical.from_codes(CArray.int8(2) { |i| [0, 127][i] },
                                          labels[0, 128]).to_a)
    assert_equal(["L0", "L255", "L1"],
                 CACategorical.from_codes(CArray.uint16(3) { |i| [0, 255, 1][i] },
                                          labels).to_a)
  end

  def test_from_codes_refuses_duplicate_labels_as_categorize_does
    # codes index into labels, so a repeated label makes the mapping
    # non-injective and every label-space member disagrees with #to_a
    assert_raise(ArgumentError) {
      CACategorical.from_codes(CArray.uint8(4) { |i| [0, 1, 2, 0][i] }, ["a", "a", "b"])
    }
  end

  def test_from_codes_refuses_an_unmasked_code_outside_the_vocabulary
    assert_raise(ArgumentError) {
      CACategorical.from_codes(CArray.uint8(4) { |i| [0, 7, 1, 200][i] }, ["a", "b"])
    }
    assert_raise(ArgumentError) {
      CACategorical.from_codes(CArray.int8(3) { |i| [0, -2, 1][i] }, ["a", "b"])
    }
  end

  def test_from_codes_accepts_the_sentinel_and_any_byte_under_a_mask
    # the sentinel is missingness, not corruption, on either sign
    assert_equal(["a", UNDEF, "b"],
                 CACategorical.from_codes(CArray.uint8(3) { |i| [0, 255, 1][i] },
                                          ["a", "b"]).to_a)
    assert_equal(["a", UNDEF, "b"],
                 CACategorical.from_codes(CArray.int8(3) { |i| [0, -1, 1][i] },
                                          ["a", "b"]).to_a)
    # a masked cell may hold any byte at all — that is the CArray contract --
    # so it is normalised, never refused
    codes = CArray.uint8(3) { |i| [0, 7, 1][i] }
    codes[1] = UNDEF
    cat = CACategorical.from_codes(codes, ["a", "b"])
    assert_equal(["a", UNDEF, "b"], cat.to_a)
    assert_equal([0, 255, 1], cat.codes.value.to_a)
  end

  def test_from_codes_copies_read_only_codes_instead_of_refusing_them
    # a zero-copy import can hand over a read-only buffer; normalising it must
    # not raise, and must not write through to the caller's array
    src = CArray.uint8(3) { |i| [0, 255, 1][i] }
    src.set_read_only_flag
    cat = CACategorical.from_codes(src, ["a", "b"])
    assert_equal(["a", UNDEF, "b"], cat.to_a)
    assert_false(src.has_mask?)

    pre = CArray.uint8(3) { |i| [0, 9, 1][i] }
    pre[1] = UNDEF
    pre.set_read_only_flag
    cat2 = CACategorical.from_codes(pre, ["a", "b"])
    assert_equal([0, 255, 1], cat2.codes.value.to_a)
    assert_equal([0, 9, 1], pre.value.to_a)        # the caller's bytes stand
  end

  def test_from_codes_stays_zero_copy_when_nothing_needs_rewriting
    # normalising is conditional: codes that already agree are adopted as-is,
    # which is what keeps a wrapped memory view a view
    src = CArray.uint8(3) { |i| [0, 1, 1][i] }
    assert_same(src, CACategorical.from_codes(src, ["a", "b"]).codes)
    sent = CArray.uint8(3) { |i| [0, 255, 1][i] }
    assert_same(sent, CACategorical.from_codes(sent, ["a", "b"]).codes)
  end

  def test_from_codes_materialises_a_view_so_its_root_cannot_change_the_codes
    # read-only is a per-object flag: setting it on a view stops
    # `cat.codes[i] = x` but not `root[i] = x`, and the categorical (plus the
    # grouping plan memoised against it) would move underneath a Face that is
    # supposed to be immutable
    root = CArray.uint8(6) { |i| [0, 1, 0, 2, 1, 0][i] }
    cat  = CACategorical.from_codes(root[1..4], ["a", "b", "c"])
    assert_true(cat.codes.entity?)
    assert_equal(["b", "a", "c", "b"], cat.to_a)

    root[1] = 200
    assert_equal(["b", "a", "c", "b"], cat.to_a)
    assert_equal([1, 0, 2, 1], cat.codes.value.to_a)
    # the caller's array is not frozen as a side effect — taking ownership of a
    # window must not freeze the bytes outside it
    assert_false(root.read_only?)
  end

  def test_from_codes_adopts_a_borrowed_entity_without_copying
    # a CAWrap over a producer's buffer is an entity, so the zero-copy import
    # stays zero-copy (that producer can still write its own buffer — the
    # borrowed-buffer bargain, which this constructor does not pretend to close)
    w = CArray.wrap_memory_view(CArray.uint8(3) { |i| [0, 1, 1][i] })
    cat = CACategorical.from_codes(w, ["a", "b"])
    assert_same(w, cat.codes)
  end

  # ---- READONLY -----------------------------------------------------------

  def test_readonly
    cat = CACategorical.from_codes(CArray.uint8(3) { |i| i }, ["a", "b", "c"])
    assert_true(cat.read_only?)
    assert_raise(RuntimeError) { cat[0] = 1 }
  end

  def test_labels_frozen
    cat = CACategorical.from_codes(CArray.uint8(3) { |i| i }, ["a", "b", "c"])
    assert_true(cat.labels.frozen?)
    assert_raise(FrozenError) { cat.labels << "d" }
    # a caller's array is not frozen as a side effect
    given = ["a", "b", "c"]
    CACategorical.from_codes(CArray.uint8(3) { |i| i }, given)
    assert_false(given.frozen?)
  end

  # ---- existing CArray methods work on the codes parent -------------------

  def test_codes_level_operations
    codes = CArray.uint8(6) { |i| [0, 1, 0, 2, 1, 0][i] }
    cat   = CACategorical.from_codes(codes, ["tokyo", "osaka", "kyoto"])

    assert_equal([3, 2, 1], cat.codes.bincount.to_a)       # per-category counts
    assert_equal(3, cat.codes.count(0))                    # count of one category
    assert_equal([false, false, false, true, false, false], cat.codes.eq(2).to_a) # category == kyoto
  end

  # ---- category-space operations (by label, not code) --------------------

  def test_eq_ne_by_label
    codes = CArray.uint8(6) { |i| [0, 1, 0, 2, 1, 0][i] }
    cat   = CACategorical.from_codes(codes, ["tokyo", "osaka", "kyoto"])

    assert_equal([true, false, true, false, false, true], cat.eq("tokyo").to_a)
    assert_equal([false, true, false, true, true, false], cat.ne("tokyo").to_a)
    assert_equal(3, cat.eq("tokyo").count(true))
  end

  def test_count_by_label
    codes = CArray.uint8(6) { |i| [0, 1, 0, 2, 1, 0][i] }
    cat   = CACategorical.from_codes(codes, ["tokyo", "osaka", "kyoto"])

    assert_equal(3, cat.count("tokyo"))
    assert_equal(1, cat.count("kyoto"))
  end

  def test_unknown_label
    cat = CACategorical.from_codes(CArray.uint8(3) { |i| i }, ["a", "b", "c"])
    assert_equal(0, cat.count("zzz"))
    assert_equal([false, false, false], cat.eq("zzz").to_a)
  end

  def test_bincount_aligned_to_labels
    # category "c" (code 2) never occurs; bincount must keep the trailing 0.
    codes = CArray.uint8(4) { |i| [0, 1, 0, 1][i] }
    cat   = CACategorical.from_codes(codes, ["a", "b", "c"])

    assert_equal([2, 2],    cat.codes.bincount.to_a)   # raw codes truncate
    assert_equal([2, 2, 0], cat.category_sizes.to_a)         # aligned to all k labels
    assert_equal([["a", 2], ["b", 2], ["c", 0]], cat.labels.zip(cat.category_sizes.to_a))
  end

  def test_eq_excluded_is_undef
    keys = CArray.object(4) { |i| ["a", "b", "z", "a"][i] }
    keys[2] = UNDEF
    cat = keys.categorize
    assert_equal([true, false, UNDEF, true], cat.eq("a").to_a)   # excluded cell stays UNDEF
  end

  # ---- view chain carries codes (parent) + labels (ivar) ------------------

  def test_slice_carries_codes_and_labels
    codes = CArray.uint8(6) { |i| [0, 1, 0, 2, 1, 0][i] }
    cat   = CACategorical.from_codes(codes, ["tokyo", "osaka", "kyoto"])
    sl    = cat[1..4]

    assert_kind_of(CACategorical, sl)
    assert_equal([1, 0, 2, 1], sl.codes.to_a)
    assert_equal(["osaka", "tokyo", "kyoto", "osaka"], sl.to_a)
    assert_equal(["tokyo", "osaka", "kyoto"], sl.labels)
  end

  # ---- exclusion: from_codes derives the mask from the sentinel -----------

  def test_from_codes_unsigned_type_max_sentinel
    # 0xFF = the reserved exclusion sentinel for uint8.
    codes = CArray.uint8(4) { |i| [0, 0xFF, 1, 0][i] }
    cat   = CACategorical.from_codes(codes, ["a", "b"])

    assert_true(cat.has_mask?)
    assert_equal([false, true, false, false], cat.is_masked.to_a)         # derived from sentinel
    assert_equal(UNDEF, cat[1])
    assert_equal(["a", UNDEF, "b", "a"], cat.to_a)
    assert_equal([2, 1], cat.codes.bincount.to_a)          # excluded dropped (no blowup)
  end

  def test_from_codes_signed_minus_one_sentinel
    # pandas-style signed codes: -1 marks missing.
    codes = CArray.int8(4) { |i| [0, -1, 1, 0][i] }
    cat   = CACategorical.from_codes(codes, ["a", "b"])

    assert_true(cat.has_mask?)
    assert_equal([false, true, false, false], cat.is_masked.to_a)
    assert_equal(UNDEF, cat[1])
    assert_equal(["a", UNDEF, "b", "a"], cat.to_a)
  end

  def test_no_exclusions_no_spurious_mask
    cat = CACategorical.from_codes(CArray.uint8(3) { |i| i }, ["a", "b", "c"])
    assert_false(cat.has_mask?)
  end

  # ---- consumer hooks: axis-group OOB + pandas/arrow byte-reinterpret -----

  def test_excluded_cells_store_sentinel_for_consumers
    keys = CArray.object(5) { |i| ["jan", "jul", "mar", "jan", "dec"][i] }
    cat  = keys.categorize(labels: ["jan", "feb", "mar"])   # jul, dec excluded

    # axis-group reads the raw codes; excluded cells store type-max (>= k),
    # caught by the kernel's [0, k) range skip with no kernel change.
    assert_equal([0, 0xFF, 2, 0, 0xFF], cat.codes.value.to_a)

    # pandas / Arrow bridge: a same-width CARefer reinterprets the bytes as
    # signed (zero-copy, no value conversion), where the sentinel reads as -1.
    signed = cat.codes.value.refer(CA_INT8)
    assert_equal(CA_INT8, signed.data_type)
    assert_equal([0, -1, 2, 0, -1], signed.to_a)
  end

  # ---- NonNumeric (FIXLEN) gate: raw numeric ops raise --------------------

  def test_numeric_ops_gated
    cat = CACategorical.from_codes(CArray.uint8(3) { |i| i }, ["a", "b", "c"])
    # surface = CA_FIXLEN -> numeric kernel dispatch is gated off
    assert_raise(RuntimeError) { cat + 1 }
  end

  # ---- keys.categorize: densify (first-appearance order) ------------------

  def test_categorize_discovers_first_appearance_order
    keys = CArray.object(8) { |i| ["mar", "mar", "jan", "jan", "jul", "jul", "jan", "mar"][i] }
    cat  = keys.categorize

    assert_kind_of(CACategorical, cat)
    assert_equal(["mar", "jan", "jul"], cat.labels)        # first-appearance, not sorted
    assert_equal([0, 0, 1, 1, 2, 2, 1, 0], cat.codes.to_a)
    assert_equal(CA_UINT8, cat.codes.data_type)            # narrow code dtype
    assert_equal(keys.to_a, cat.to_a)                      # decode round-trips
  end

  def test_categorize_fixed_labels_excludes_off_set
    keys = CArray.object(5) { |i| ["jan", "jul", "mar", "jan", "dec"][i] }
    cat  = keys.categorize(labels: ["jan", "feb", "mar"])

    assert_equal(["jan", "feb", "mar"], cat.labels)
    assert_equal(0, cat.codes.to_a[0])                     # jan -> 0
    assert_equal(2, cat.codes.to_a[2])                     # mar -> 2
    assert_true(cat.has_mask?)
    assert_equal(UNDEF, cat[1])                            # jul not in set -> excluded
    assert_equal(UNDEF, cat[4])                            # dec not in set -> excluded
  end

  def test_categorize_masked_keys_excluded
    keys = CArray.object(4) { |i| ["a", "b", "z", "a"][i] }
    keys[2] = UNDEF
    cat = keys.categorize

    assert_true(cat.has_mask?)
    assert_equal(true, cat.is_masked.to_a[2])
    assert_equal(UNDEF, cat[2])
    assert_equal(["a", "b"], cat.labels)                   # masked key not a level
  end

  def test_categorize_rejects_duplicate_labels
    keys = CArray.object(3) { |i| ["a", "b", "c"][i] }
    assert_raise(ArgumentError) { keys.categorize(labels: ["a", "a", "b"]) }
  end

  def test_categorize_multidimensional
    # Regression: the discovered path must flatten correctly for ndim > 1.
    keys = CArray.object(2, 2) { |i, j| [["x", "y"], ["x", "z"]][i][j] }
    cat  = keys.categorize

    assert_equal([2, 2], cat.shape)
    assert_equal(["x", "y", "z"], cat.labels)
    assert_equal([[0, 1], [0, 2]], cat.codes.to_a)
    assert_equal([["x", "y"], ["x", "z"]], cat.to_a)
  end

  # ---- sort_labels: opt-in for ascending vocabulary --------------------

  def test_sort_labels_ascending
    # snap → categorize is the canonical continuous→categorical path;
    # sort_labels: true gives ascending labels so downstream tables read
    # in numeric order regardless of first-appearance.
    keys = CArray.object(6) { |i| %w[mar jan jul jan mar jul][i] }
    cat  = keys.categorize(sort_labels: true)

    assert_equal(["jan", "jul", "mar"], cat.labels)         # sorted
    assert_equal(keys.to_a, cat.to_a)                       # round-trips
    # codes reflect the sorted-label mapping: jan=0, jul=1, mar=2
    assert_equal([2, 0, 1, 0, 2, 1], cat.codes.to_a)
  end

  def test_sort_labels_numeric_from_snap
    # user's motivating case: 0.5 K bins over temperatures.
    temp = CA_FLOAT64([271.2, 285.5, 270.0, 285.5, 299.5])
    cat  = temp.snap(0.5).categorize(sort_labels: true)
    assert_equal([270.0, 271.0, 285.5, 299.5], cat.labels)  # ascending
    assert_equal(temp.snap(0.5).to_a, cat.to_a)             # decode round-trips
  end

  def test_sort_labels_default_false
    # backward-compat: default remains first-appearance order.
    keys = CArray.object(4) { |i| %w[c a b a][i] }
    cat  = keys.categorize
    assert_equal(["c", "a", "b"], cat.labels)               # first-appearance
  end

  def test_sort_labels_ignored_when_labels_given
    # When labels: is explicit, the caller has decided the order;
    # sort_labels: does not override.
    keys = CArray.object(3) { |i| %w[b a c][i] }
    cat  = keys.categorize(labels: %w[c b a], sort_labels: true)
    assert_equal(["c", "b", "a"], cat.labels)               # as given, not sorted
  end

  # ---- reduceat / sort-based grouping foundation -------------------------
  #
  # sort_addr + reduceat_index lay the data out as category-contiguous blocks
  # so a consumer can select per block — the engine for order statistics
  # (median / percentile) that the scatter kernel (axis_group) cannot do.

  def test_reduceat_index_offsets
    cat = CA_INT([2, 0, 1, 2, 0, 0, 1, 2]).categorize(labels: [0, 1, 2])
    assert_equal([3, 2, 3], cat.category_sizes.to_a)              # block lengths
    assert_equal([0, 3, 5], cat.reduceat_index.to_a)        # block starts
  end

  def test_sort_addr_groups_codes_contiguously
    cat  = CA_INT([2, 0, 1, 2, 0, 0, 1, 2]).categorize(labels: [0, 1, 2])
    flat = cat.codes.value.reshape(8).to_a
    sorted = cat.sort_addr.to_a.map { |a| flat[a] }
    assert_equal([0, 0, 0, 1, 1, 2, 2, 2], sorted)          # non-decreasing
  end

  def test_reduceat_roundtrip_per_block_sum
    keys = CA_INT([2, 0, 1, 2, 0, 0, 1, 2])
    cat  = keys.categorize(labels: [0, 1, 2])
    val  = CA_DOUBLE([10, 20, 30, 40, 50, 60, 70, 80])

    grouped = val[cat.sort_addr]
    idx = cat.reduceat_index
    cnt = cat.category_sizes
    got = (0...cat.labels.size).map { |c| grouped[idx[c]...(idx[c] + cnt[c])].sum }

    # ground-truth groupby-sum
    want = [0, 1, 2].map { |lab| keys.to_a.each_index.select { |i| keys[i] == lab }.sum { |i| val[i] } }
    assert_equal(want, got)
  end

  def test_excluded_cells_land_in_tail
    keys = CA_INT([2, 0, 1, 9, 0])                          # 9 = out-of-vocab
    cat  = keys.categorize(labels: [0, 1, 2])
    val  = CA_DOUBLE([10, 20, 30, 999, 50])

    grouped = val[cat.sort_addr]
    total_valid = cat.category_sizes.to_a.sum                     # excluded not counted
    assert_equal(4, total_valid)
    assert_equal([999.0], grouped[total_valid..-1].to_a)    # excluded pushed past the blocks
  end

  def test_reduceat_multidimensional_roundtrip
    keys = CA_INT([[1, 0, 2, 1], [2, 2, 0, 1]])
    cat  = keys.categorize(labels: [0, 1, 2])
    val  = CArray.double(2, 4) { |i, j| (i * 4 + j) * 1.0 }

    grouped = val.reshape(8)[cat.sort_addr]                 # flat addrs into raveled storage
    idx = cat.reduceat_index
    cnt = cat.category_sizes
    got = (0...cat.labels.size).map { |c| grouped[idx[c]...(idx[c] + cnt[c])].sum }

    flat = val.reshape(8)
    want = [0, 1, 2].map { |lab| keys.reshape(8).to_a.each_index.select { |i| keys.reshape(8)[i] == lab }.sum { |i| flat[i] } }
    assert_equal(8, cat.sort_addr.elements)
    assert_equal(want, got)
  end

  def test_per_category_median_via_foundation
    # the payoff: an order statistic scatter cannot produce.
    keys = CA_INT([1, 0, 1, 0, 1, 0, 0, 1])
    cat  = keys.categorize(labels: [0, 1])
    val  = CA_DOUBLE([5, 100, 9, 10, 1, 40, 30, 7])

    grouped = val[cat.sort_addr]
    idx = cat.reduceat_index
    cnt = cat.category_sizes
    med = (0...cat.labels.size).map { |c| grouped[idx[c]...(idx[c] + cnt[c])].median }

    want = [0, 1].map do |lab|
      vs = keys.to_a.each_index.select { |i| keys[i] == lab }.map { |i| val[i] }.sort
      vs.size.odd? ? vs[vs.size / 2] : (vs[vs.size / 2 - 1] + vs[vs.size / 2]) / 2.0
    end
    assert_equal(want, med)
  end

  def test_reduceat_index_empty_category_zero_width
    # a category with no cells yields a zero-width block (start repeats).
    cat = CA_INT([0, 0, 2, 2]).categorize(labels: [0, 1, 2])  # label 1 empty
    assert_equal([2, 0, 2], cat.category_sizes.to_a)
    assert_equal([0, 2, 2], cat.reduceat_index.to_a)          # block 1 is [2,2) = empty
  end

  # ---- value-hash discovery family (label space, not code space) --------
  #
  # The codes are storage and the labels are the values, so the family answers
  # in labels.  Before these overrides `unique` handed back the raw code bytes
  # and `is_in` compared labels against codes -- false everywhere
  # (devel/PROPOSAL_DISCOVERY_FAMILY_FACE_GATE.md Phase 3).

  def test_discovery_answers_in_label_space
    # labels land in first-appearance order: b, a, c
    cat = CA_OBJECT(%w[b a b c]).categorize
    assert_equal %w[b a c], cat.unique.to_a
    assert_equal %w[a b c], cat.unique(sort: true).to_a
    assert_equal [%w[b a c], [2, 1, 1]], cat.value_counts.map(&:to_a)
    assert_equal [%w[a b c], [1, 2, 1]], cat.value_counts(sort: :value).map(&:to_a)
    assert_equal ["b"], cat.mode.to_a
  end

  def test_discovery_membership_and_set_operations_take_labels
    cat = CA_OBJECT(%w[b a b c]).categorize
    assert_equal [false, true, false, true], cat.is_in(%w[a c]).to_a
    assert_equal [false, false, false, false], cat.is_in(%w[zz]).to_a
    assert_equal %w[a], cat.intersection(%w[a zz]).to_a
    assert_equal %w[a c], cat.difference(%w[b]).to_a
    assert_equal %w[b a c zz], cat.union(%w[zz]).to_a
    assert_equal [0, 1, 0, 2], cat.locate_addr(cat.unique).to_a
  end

  def test_discovery_skips_masked_cells
    keys = CArray.object(4) { |i| %w[a b a c][i] }
    keys[1] = UNDEF
    cat = keys.categorize
    assert_equal %w[a c], cat.unique.to_a
    assert_equal [%w[a c], [2, 1]], cat.value_counts.map(&:to_a)
    assert_equal [true, UNDEF, true, false], cat.is_in(%w[a]).to_a
  end

  def test_discovery_leaves_the_already_correct_members_alone
    cat = CA_OBJECT(%w[b a b c]).categorize
    assert_equal 3, cat.nunique
    assert_equal [true, false, true, false], cat.is_mode.to_a
    assert_equal 2, cat.count("b")
    assert_equal [2, 1, 1], cat.category_sizes.to_a
  end
end

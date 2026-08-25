# PROPOSAL_CATEXT.md T.7 — CAConstString comprehensive test matrix.
#
# Covers AC2-AC8 from §5 Acceptance criteria.  AC1 (validate-first) is
# subsumed by AC3 (fetch) + AC4 (numeric gate).  Regression sweep is `rake
# spec_ai`.

require "test/unit"
require "carray"

class TestCAConstString < Test::Unit::TestCase

  WORDS = ["alpha", "", "gamma", "delta", "z"].freeze

  # =========================================================================
  # AC2 — construction (Array / block / wrap / to_text), nil/"" semantics, N-D
  # =========================================================================

  def test_ac2_array_form
    ct = CArray.const_string(WORDS)
    assert_kind_of CAConstString, ct
    assert_equal :fixlen, ct.data_type           # FIXLEN gate surface (§3.3)
    assert_equal 5, ct.elements
    assert_equal WORDS, ct.to_a
  end

  def test_ac2_block_form
    ct = CArray.const_string(3) { |i| "item#{i}" }
    assert_equal ["item0", "item1", "item2"], ct.to_a
  end

  def test_ac2_arity0_broadcast_quirk
    # B5: arity-0 block evaluated once and broadcast (consistency with
    # CArray.<type>(n){ ... }).
    ct = CArray.const_string(3) { "X" }
    assert_equal ["X", "X", "X"], ct.to_a
  end

  def test_ac2_nil_is_masked_empty_is_empty
    # B1: nil -> masked element; "" -> valid empty string (distinct).
    ct = CArray.const_string(["a", "", nil, "b"])
    assert ct.has_mask?
    assert_equal [false, false, true, false], ct.is_masked.to_a
    assert_equal "", ct[1]
    assert_equal UNDEF, ct[2]
  end

  def test_ac2_wrap_low_level
    words = ["a", "bb", "ccc"]
    buf   = words.join.b                                   # pure concat, no length prefix
    offs  = [0]; words.each { |w| offs << offs[-1] + w.bytesize }
    pairs = (0...words.size).flat_map { |i| [offs[i], offs[i + 1]] }
    pe    = CArray.new(CA_FIXLEN, [words.size], :bytes => 16)
    pe.load_binary(pairs.pack("q*"))
    ct    = CAConstString.wrap(pe, buffer: buf, encoding: Encoding::UTF_8)
    assert_equal words, ct.to_a
  end

  def test_ac2_wrap_requires_buffer
    pe = CArray.new(CA_FIXLEN, [1], :bytes => 16)
    assert_raise(ArgumentError) { CAConstString.wrap(pe) }
  end

  def test_ac2_wrap_rejects_non_pair_parent
    # storage must be a fixlen-16 (start,end) pair entity
    assert_raise(TypeError) { CAConstString.wrap(CArray.float64(2) { 0.0 }, buffer: "x") }
    # the old int64 offset entity (pre-Arrow layout) is no longer accepted
    assert_raise(TypeError) { CAConstString.wrap(CArray.int64(2) { 0 }, buffer: "x") }
    # fixlen of the wrong width
    assert_raise(TypeError) { CAConstString.wrap(CArray.new(CA_FIXLEN, [2], :bytes => 8), buffer: "x") }
  end

  def test_ac2_to_text_round_trip
    obj = CArray.object(4) { |i| ["a", "bb", "ccc", "d"][i] }
    obj[2] = UNDEF
    ct = CArray.const_string(obj)
    assert_kind_of CAConstString, ct
    assert ct.has_mask?
    assert_equal [false, false, true, false], ct.is_masked.to_a
    assert_equal ["a", "bb", nil, "d"], ct.to_a.map { |v| v == UNDEF ? nil : v }
  end

  def test_ac2_nd_grid
    # B6: N-D string grid.
    ct = CArray.const_string(6) { |i| "c#{i}" }.reshape(2, 3)
    assert_equal [2, 3], ct.shape
    assert_equal "c5", ct[1, 2]
  end

  def test_ac2_zero_elements
    ct = CArray.const_string([])
    assert_equal 0, ct.elements
    assert_equal [], ct.to_a
  end

  # =========================================================================
  # AC3 — fetch returns frozen Ruby String; views (slice/mask) decode
  # =========================================================================

  def test_ac3_fetch_frozen_string
    ct = CArray.const_string(WORDS)
    assert_equal "alpha", ct[0]
    assert ct[0].frozen?
    assert_equal Encoding::UTF_8, ct[0].encoding
  end

  def test_ac3_encoding_preserved
    ct = CArray.const_string(["日本語", "x"])
    assert_equal "日本語", ct[0]
    assert_equal Encoding::UTF_8, ct[0].encoding
  end

  def test_ac3_slice_is_view
    ct = CArray.const_string(WORDS)
    sl = ct[1..3]
    assert_kind_of CAConstString, sl
    assert_equal ["", "gamma", "delta"], sl.to_a
  end

  def test_ac3_mask_is_view
    ct = CArray.const_string(WORDS)
    m  = CArray.boolean(5) { |i| i.even? }
    sel = ct[m]
    assert_kind_of CAConstString, sel
    assert_equal ["alpha", "gamma", "z"], sel.to_a
  end

  def test_ac3_masked_fetch_is_undef
    ct = CArray.const_string(["a", nil, "b"])
    assert_equal UNDEF, ct[1]
  end

  # =========================================================================
  # AC4 — numeric gate: numeric reductions raise (no silent garbage, §5)
  # =========================================================================

  def test_ac4_numeric_ops_gated
    ct = CArray.const_string(WORDS)
    assert_raise(CArray::DataTypeError) { ct.sum }
    assert_raise(CArray::DataTypeError) { ct.mean }
    assert_raise(CArray::DataTypeError) { ct.variance }
    assert_raise(CArray::DataTypeError) { ct.prod }
  end

  # =========================================================================
  # AC5 — native byte ops are byte-for-byte faithful to Ruby String semantics
  # =========================================================================

  def test_ac5_eq_scalar
    ct = CArray.const_string(["foo", "bar", "foo"])
    assert_equal [true, false, true], ct.eq("foo").to_a
  end

  def test_ac5_eq_elementwise
    a = CArray.const_string(["x", "y", "z"])
    b = CArray.const_string(["x", "Y", "z"])
    assert_equal [true, false, true], a.eq(b).to_a
  end

  def test_ac5_byte_length
    ct = CArray.const_string(["a", "bb", "日本"])   # 1, 2, 6 bytes
    assert_equal [1, 2, 6], ct.byte_length.to_a
  end

  def test_ac5_count
    ct = CArray.const_string(["a", "b", "a", "a"])
    assert_equal 3, ct.count("a")
    assert_equal 0, ct.count("z")
  end

  def test_ac5_predicates
    ct = CArray.const_string(["apple", "apricot", "banana"])
    assert_equal [true, true, false], ct.start_with?("ap").to_a
    assert_equal [false, false, true], ct.end_with?("a").to_a   # only "banana" ends with "a"
    assert_equal [false, false, true], ct.include?("an").to_a   # only "banana" contains "an"
  end

  def test_ac5_sort_faithful
    words = ["banana", "apple", "Cherry", "apple", ""]
    ct = CArray.const_string(words)
    assert_equal words.sort, ct.sort.to_a
  end

  def test_ac5_sort_index
    ct = CArray.const_string(["c", "a", "b"])
    assert_equal [1, 2, 0], ct.sort_index.to_a
  end

  def test_ac5_sort_is_nocopy_view
    ct = CArray.const_string(["b", "a"])
    s  = ct.sort
    assert ct.buffer.equal?(s.buffer)         # no string bytes move
    refute s.parent.entity?                    # offsets gathered lazily, not materialized
  end

  def test_ac5_sort_copy_is_standalone
    ct = CArray.const_string(["b", "a", "c"])
    sc = ct.sort_copy
    assert_kind_of CAConstString, sc
    assert_equal ["a", "b", "c"], sc.to_a
    refute sc.buffer.equal?(ct.buffer)         # owned, compacted buffer
  end

  def test_ac5_min_max
    words = ["banana", "apple", "cherry"]
    ct = CArray.const_string(words)
    assert_equal words.min, ct.min
    assert_equal words.max, ct.max
  end

  def test_ac5_min_max_skip_masked
    ct = CArray.const_string(["b", "a", nil])
    assert_equal "a", ct.min
    assert_equal "b", ct.max
  end

  def test_ac5_min_all_masked_is_nil
    ct = CArray.const_string([nil, nil])
    assert_nil ct.min
  end

  def test_ac5_sort_masked_raises
    ct = CArray.const_string(["b", "a", nil])
    assert_raise(ArgumentError) { ct.sort }
  end

  # =========================================================================
  # AC6 — copy = compacting deep copy (rebased, compacted, mask carried, N-D)
  # =========================================================================

  def test_ac6_copy_compacts_buffer
    big   = CArray.const_string(Array.new(100) { "xxxxx" })   # pure concat: 100 * 5 = 500
    small = big[0..1].copy
    assert small.buffer.bytesize < big.buffer.bytesize
    assert_equal 2 * 5, small.buffer.bytesize                 # no per-record length prefix
  end

  def test_ac6_copy_values_and_mask
    ct = CArray.const_string(["alpha", "", "gamma", nil, "z"])
    cp = ct[1..4].copy
    assert_kind_of CAConstString, cp
    assert_equal ["", "gamma", nil, "z"], cp.to_a.map { |v| v == UNDEF ? nil : v }
    assert_equal [false, false, true, false], cp.is_masked.to_a
  end

  def test_ac6_to_ca_alias
    ct = CArray.const_string(["a", "b"])
    assert_kind_of CAConstString, ct.to_ca
  end

  def test_ac6_copy_nd_shape
    nd  = CArray.const_string(6) { |i| "c#{i}" }.reshape(2, 3)
    cp  = nd.copy
    assert_equal [2, 3], cp.shape
    assert_equal "c5", cp[1, 2]
  end

  # =========================================================================
  # copy of a fancy-index view (repeated elements)
  # =========================================================================
  #
  # There is no offset-sharing dedup: copy repacks every element's bytes in
  # logical order (high-duplication columns belong in CACategorical / Arrow
  # DictionaryArray, not here).

  def test_copy_of_repeated_index_view
    base = CArray.const_string(["red", "green", "blue"])
    view = base[CArray.int64(6) { |i| [0, 0, 1, 1, 0, 2][i] }]
    cp   = view.copy
    assert_kind_of CAConstString, cp
    assert_equal ["red", "red", "green", "green", "red", "blue"], cp.to_a
    # pure concat, every element repacked (no sharing)
    assert_equal ("red" + "red" + "green" + "green" + "red" + "blue").bytesize,
                 cp.buffer.bytesize
  end

  # =========================================================================
  # AC7 — GC safety: custom dmark pins the buffer; decode survives compaction
  # =========================================================================

  def test_ac7_gc_compact_safe
    ct = CArray.const_string(["persistent", "data", "here"])
    GC.start
    GC.compact if GC.respond_to?(:compact)
    GC.start
    assert_equal ["persistent", "data", "here"], ct.to_a
  end

  # =========================================================================
  # AC8 — edge cases: empty vs masked, NUL bytes, encoding strict
  # =========================================================================

  def test_ac8_empty_string_not_masked
    ct = CArray.const_string(["", "a"])
    refute ct.has_mask?              # no nil -> no mask
    assert_equal "", ct[0]
    assert_equal [0, 1], ct.byte_length.to_a
  end

  def test_ac8_nul_bytes_preserved
    ct = CArray.const_string(["a\x00b"])
    assert_equal [97, 0, 98], ct[0].bytes
    assert_equal 3, ct.byte_length[0]
  end

  def test_ac8_encoding_strict_raises
    bad = (+"x").force_encoding("ISO-8859-1") << 0xff.chr
    assert_raise(ArgumentError) { CArray.const_string([bad], encoding: Encoding::UTF_8) }
  end

  def test_ac8_ascii_compatible_relaxation
    # B2: pure-ASCII strings pass regardless of declared encoding.
    s = (+"hello").force_encoding("ASCII-8BIT")
    ct = CArray.const_string([s], encoding: Encoding::UTF_8)
    assert_equal "hello", ct[0]
  end

  # =========================================================================
  # to_string escape (CAConstString -> CAString) + introspection
  # =========================================================================

  def test_to_string_escape
    ct = CArray.const_string(["a", "bb", nil])
    s  = ct.to_string
    assert_kind_of CAString, s        # object-storage mutable String Face
    assert s.has_mask?
    assert_equal [false, false, true], s.is_masked.to_a
    s[0] = "MUT"                       # mutable, independent of the const source
    assert_equal "MUT", s[0]
    assert_equal "a", ct[0]            # original CAConstString untouched
  end

  def test_introspection
    ct = CArray.const_string(["a"], encoding: Encoding::UTF_8)
    assert_equal Encoding::UTF_8, ct.encoding
    assert_kind_of String, ct.buffer
    assert ct.buffer.frozen?
  end

  # =========================================================================
  # native exact-lookup search (offset+buffer storage can't use the kernels)
  # =========================================================================

  def test_search_first_match_index
    ct = CArray.const_string(["banana", "apple", "cherry", "apple"])
    assert_equal 1, ct.search("apple")        # first match
    assert_equal 2, ct.search("cherry")
  end

  def test_search_not_found_is_nil
    ct = CArray.const_string(["a", "b", "c"])
    assert_nil ct.search("zzz")
  end

  def test_find_value_index_alias
    ct = CArray.const_string(["x", "y", "z"])
    assert_equal 2, ct.find_value_index("z")
    assert_nil ct.find_value_index("q")
  end

  def test_search_skips_masked
    ct = CArray.const_string(["a", nil, "a", "b"])
    assert_equal 0, ct.search("a")            # idx 1 is masked, idx 2 also "a"
  end

  def test_search_empty_string
    ct = CArray.const_string(["a", "", "b"])
    assert_equal 1, ct.search("")             # "" is a valid distinct value
  end

  # in? marks every cell in the given set (both "apple" cells)
  def test_in_membership
    ct = CArray.const_string(["banana", "apple", "cherry", "apple"])
    assert_equal [false, true, true, true], ct.in?("apple", "cherry").to_a
  end

  # template returns a PLAIN entity, never the Face (a Face's blank template
  # is not well-defined: a boolean retype is a different buffer, and a blank
  # CAConstString has no offset+buffer form).  Both retype and same-type are
  # plain; the result is fillable.
  def test_template_is_plain_not_face
    ct = CArray.const_string(["a", "b"])
    assert_equal CArray, ct.template(:boolean).class
    assert_equal CArray, ct.template.class
    t = ct.template(:object)
    t[0] = "x"                                # fillable (not a broken Face)
    assert_equal "x", t[0]
  end

  # ---- value-hash discovery family (string space, not storage space) ----
  #
  # A storage cell is a (start, end) byte range, so storage equality is not
  # string equality: before these overrides `%w[ab cd ab ef].nunique` answered
  # 4.  The class runs the family on #to_string and rebuilds value outputs as a
  # CAConstString (devel/PROPOSAL_DISCOVERY_FAMILY_FACE_GATE.md Phase 2).

  def dup_strings
    CArray.const_string(%w[ab cd ab ef])
  end

  def test_discovery_counts_equal_strings_as_one
    cs = dup_strings
    assert_equal 3, cs.nunique
    assert_equal %w[ab cd ef], cs.unique.to_a
    assert_instance_of CAConstString, cs.unique
    values, counts = cs.value_counts
    assert_instance_of CAConstString, values
    assert_equal %w[ab cd ef], values.to_a
    assert_equal [2, 1, 1], counts.to_a
  end

  def test_discovery_mode_and_duplicates
    cs = dup_strings
    assert_instance_of CAConstString, cs.mode
    assert_equal ["ab"], cs.mode.to_a
    assert_equal [true, false, true, false], cs.is_mode.to_a
    md = cs.mask_duplicates
    assert_instance_of CAConstString, md
    assert_equal [false, false, true, false], md.is_masked.to_a
  end

  def test_discovery_membership_and_set_operations
    cs = dup_strings
    assert_equal [true, false, true, false], cs.is_in(%w[ab]).to_a
    assert_equal [true, false, true, false],
                 cs.is_in(CArray.const_string(%w[ab])).to_a
    assert_equal %w[ab], cs.intersection(CArray.const_string(%w[ab zz])).to_a
    assert_equal %w[cd ef], cs.difference(CArray.const_string(%w[ab])).to_a
    assert_equal %w[ab cd ef zz], cs.union(CArray.const_string(%w[zz])).to_a
    assert_instance_of CAConstString, cs.intersection(%w[ab])
    assert_equal [0, 1, 0, 2], cs.locate_addr(cs.unique).to_a
  end

  def test_discovery_categorize_keys_on_the_strings
    cs = dup_strings
    cat = cs.categorize
    assert_equal %w[ab cd ef], cat.labels
    assert_equal [0, 1, 0, 2], cat.codes.to_a
  end

  def test_discovery_skips_masked_cells
    cs = CArray.const_string(%w[ab cd ab])
    cs.parent[1] = UNDEF
    assert_equal 1, cs.nunique
    assert_equal %w[ab], cs.unique.to_a
  end
end

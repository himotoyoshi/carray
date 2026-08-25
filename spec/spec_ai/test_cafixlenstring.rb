# PROPOSAL_STRING_FACE_TRIO.md P.2 — CAFixlenString (identity Face over
# CA_FIXLEN storage) working-class test matrix.
#
# At the Face layer this is a plain fixlen->fixlen identity Face (sibling of
# CAString over CA_OBJECT).  fetch/store use the native fixlen path: values
# are NUL-padded to the slot width and over-length values truncate silently
# at per-cell store.  The truncate policy lives at the construction surface.
#
# Regression sweep is `rake spec_ai`.

require "test/unit"
require "carray"

class TestCAFixlenString < Test::Unit::TestCase

  WORDS = ["banana", "apple", "cherry", "apple"].freeze

  # ---- construction ------------------------------------------------------

  def test_construct_auto_width
    s = CArray.fixlen_string(WORDS)
    assert_kind_of CAFixlenString, s
    assert_equal :fixlen, s.data_type
    assert_equal 6, s.bytes                 # max bytesize ("banana"/"cherry")
    assert_equal 4, s.elements
  end

  def test_construct_explicit_width
    s = CArray.fixlen_string(["ab", "cde"], bytes: 4)
    assert_equal 4, s.bytes                        # storage stays K-wide (padded)
    assert_equal ["ab", "cde"], s.to_a             # fetch strips trailing NUL
  end

  def test_construct_block_form
    s = CArray.fixlen_string(3, bytes: 3) { |i| "x#{i}" }
    assert_equal ["x0", "x1", "x2"], s.to_a
  end

  def test_construct_nil_masks
    s = CArray.fixlen_string(["a", nil, "c"], bytes: 3)
    assert_equal true, s.has_mask?
    assert_equal [false, true, false], s.is_masked.to_a
    assert_equal UNDEF, s[1]
  end

  def test_wrap_rejects_non_fixlen_storage
    assert_raise(TypeError) { CAFixlenString.wrap(CArray.int32(3)) }
  end

  # ---- truncate policy (construction surface) ----------------------------

  def test_truncate_error_default_raises
    assert_raise(ArgumentError) { CArray.fixlen_string(["toolong"], bytes: 4) }
  end

  def test_truncate_silent_keeps_leading_bytes
    s = CArray.fixlen_string(["toolong"], bytes: 4, truncate: :silent)
    assert_equal "tool", s[0]
  end

  def test_truncate_invalid_symbol_raises
    assert_raise(ArgumentError) { CArray.fixlen_string(["a"], bytes: 4, truncate: :bogus) }
  end

  # ---- Face identity -----------------------------------------------------

  def test_face_hierarchy
    s = CArray.fixlen_string(WORDS)
    assert_equal true, s.face?
    [CAFace, CAView, CArray].each { |k| assert_kind_of k, s }
    assert_operator s.class.ancestors.index(CAFace), :<, s.class.ancestors.index(CArray)
  end

  def test_view_chain_lift
    s = CArray.fixlen_string(WORDS)
    assert_kind_of CAFixlenString, s[1..2]
    assert_kind_of CAFixlenString, s.reshape(2, 2)
  end

  # ---- per-cell ----------------------------------------------------------

  def test_fetch_strips_padding
    s = CArray.fixlen_string(WORDS)      # width 6
    assert_equal "banana", s[0]          # exact width
    assert_equal "apple", s[1]           # trailing NUL padding stripped on fetch
  end

  def test_store_silent_truncate_per_cell
    s = CArray.fixlen_string(["aa", "bb"], bytes: 3)
    s[0] = "toolong"                     # native fixlen store truncates silently
    assert_equal "too", s[0]
  end

  # ---- ordering (memcmp; fixlen sort gate is exempt) ---------------------

  def test_sort_index_memcmp
    s = CArray.fixlen_string(["c", "a", "b"])
    assert_equal [1, 2, 0], s.sort_index.to_a
  end

  def test_sort_view
    s = CArray.fixlen_string(["c", "a", "b"])
    assert_kind_of CAFixlenString, s.sort
    assert_equal ["a", "b", "c"], s.sort.to_a
  end

  # min / max / min_index / max_index ride the CA_FIXLEN reduction path
  # (memcmp order, same as sort_index); CAFixlenString inherits it as an
  # identity Face over fixlen storage.
  def test_min_max_memcmp
    s = CArray.fixlen_string(["c", "a", "b"])
    assert_equal "a", s.min
    assert_equal "c", s.max
    assert_equal 1, s.min_index
    assert_equal 0, s.max_index
  end

  def test_min_max_skip_masked
    s = CArray.fixlen_string(["c", "a", "b"])
    s[1] = UNDEF               # mask the smallest cell
    assert_equal "b", s.min    # "a" skipped
    assert_equal "c", s.max
    assert_equal 2, s.min_index
  end

  # ---- copy / dup --------------------------------------------------------

  def test_copy_materializes
    s = CArray.fixlen_string(WORDS)
    c = s.copy
    assert_kind_of CAFixlenString, c
    assert_equal s.to_a, c.to_a
  end

  def test_dup_is_cafixlenstring
    assert_kind_of CAFixlenString, CArray.fixlen_string(WORDS).dup
  end

  # ---- N-D ---------------------------------------------------------------

  def test_ndim
    s = CArray.fixlen_string(6, bytes: 2) { |i| i.to_s }.reshape(2, 3)
    assert_equal [2, 3], s.shape
    assert_equal "4", s[1, 1]
  end

  # ---- ORDERABLE + COMPARABLE (surface IS storage) ----------------------
  #
  # A cell decodes to its own bytes, padding included, so the descent to storage
  # is the identity map: memcmp order is String#<=> order and byte equality is
  # cell equality.  Declaring both flags therefore costs nothing and lets the
  # value-hash and search families treat it as any other ordered Face.

  def fixlen_abc
    CArray.fixlen_string(%w[ab cd ab])
  end

  def test_value_hash_family_keeps_the_class
    f = fixlen_abc
    assert_instance_of CAFixlenString, f.unique
    assert_equal %w[ab cd], f.unique.to_a
    assert_equal 2, f.nunique
    values, counts = f.value_counts
    assert_instance_of CAFixlenString, values
    assert_equal [%w[ab cd], [2, 1]], [values.to_a, counts.to_a]
    assert_instance_of CAFixlenString, f.mode
    assert_equal %w[ab], f.mode.to_a
    assert_instance_of CAFixlenString, f.intersection(f[0..0])
    assert_equal [true, false, true], f.is_in(f[0..0]).to_a
  end

  def test_search_family_takes_a_cell_query
    f = fixlen_abc.sort            # memcmp order, which is its own sort order
    assert_equal %w[ab ab cd], f.to_a
    assert_equal 2, f.bsearch(f[2])
    assert_equal 2, f.search(f[2])
    # each cell of the unsorted array, placed on the sorted one
    assert_equal [0, 2, 0], fixlen_abc.locate_addr(f).to_a
  end

  def test_a_plain_fixlen_array_is_unaffected
    # the flags live on the Face; plain CA_FIXLEN storage is not one
    plain = CArray.fixlen(3, bytes: 2) { |i| %w[ab cd ab][i] }
    assert_equal false, plain.face?
    assert_equal false, plain.is_a?(CAFixlenString)
    assert_instance_of CArray, plain.unique
    assert_equal %w[ab cd], plain.unique.to_a
  end
end

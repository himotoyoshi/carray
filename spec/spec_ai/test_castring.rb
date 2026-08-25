# PROPOSAL_STRING_FACE_TRIO.md P.1 — CAString (identity Face over CA_OBJECT
# storage) working-class test matrix.
#
# Pins the §1.6 common surface contract for CAString, minus the deferred
# str_* / conversion rows.  Regression sweep is `rake spec_ai`.

require "test/unit"
require "carray"

class TestCAString < Test::Unit::TestCase

  WORDS = ["banana", "apple", "cherry", "apple"].freeze

  # ---- construction ------------------------------------------------------

  def test_construct_array_form
    s = CArray.string(WORDS)
    assert_kind_of CAString, s
    assert_equal :object, s.data_type      # surface == storage (no gate)
    assert_equal 4, s.elements
    assert_equal WORDS, s.to_a
  end

  def test_construct_block_form
    s = CArray.string(3) { |i| "item#{i}" }
    assert_equal ["item0", "item1", "item2"], s.to_a
  end

  def test_construct_block_arity0_broadcast
    s = CArray.string(3) { "x" }
    assert_equal ["x", "x", "x"], s.to_a
  end

  def test_construct_nil_masks
    s = CArray.string(["a", nil, "c"])
    assert_equal true, s.has_mask?
    assert_equal [false, true, false], s.is_masked.to_a
    assert_equal UNDEF, s[1]
  end

  def test_wrap_zero_copy
    o = CArray.object(2)
    o[0] = "p"; o[1] = "q"
    s = CAString.wrap(o)
    s[0] = "P"
    assert_equal "P", o[0]                  # write-through to parent
  end

  def test_wrap_rejects_non_object_storage
    assert_raise(TypeError) { CAString.wrap(CArray.int32(3)) }
  end

  # ---- Face identity -----------------------------------------------------

  def test_face_hierarchy
    s = CArray.string(WORDS)
    assert_equal true, s.face?
    [CAFace, CAView, CArray].each { |k| assert_kind_of k, s }
    assert_operator s.class.ancestors.index(CAFace), :<, s.class.ancestors.index(CArray)
  end

  def test_view_chain_lift
    s = CArray.string(WORDS)
    assert_kind_of CAString, s[1..2]
    assert_equal ["apple", "cherry"], s[1..2].to_a
    assert_kind_of CAString, s.reshape(2, 2)
  end

  # ---- per-cell ----------------------------------------------------------

  def test_fetch_returns_string
    s = CArray.string(WORDS)
    assert_kind_of String, s[0]
    assert_equal "banana", s[0]
  end

  def test_store_string
    s = CArray.string(WORDS)
    s[0] = "zzz"
    assert_equal "zzz", s[0]
  end

  # ---- ordering (ORDERABLE -> :object <=> kernel, free) ------------------

  def test_sort_index
    s = CArray.string(WORDS)
    assert_equal [1, 3, 0, 2], s.sort_index.to_a
  end

  def test_min_max
    s = CArray.string(WORDS)
    assert_equal "apple", s.min
    assert_equal "cherry", s.max
  end

  # ---- copy / dup --------------------------------------------------------

  def test_copy_materializes
    s = CArray.string(WORDS)
    c = s.copy
    assert_kind_of CAString, c
    assert_equal WORDS, c.to_a
    c[0] = "X"
    assert_equal "banana", s[0]             # copy is independent
  end

  def test_dup_is_castring
    s = CArray.string(WORDS)
    assert_kind_of CAString, s.dup
  end

  # ---- N-D ---------------------------------------------------------------

  def test_ndim
    s = CArray.string(6) { |i| i.to_s }.reshape(2, 3)
    assert_equal 2, s.ndim
    assert_equal [2, 3], s.shape
    assert_equal "4", s[1, 1]
  end

end

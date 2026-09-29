require "test/unit"
require "carray"

# Regressions for four bugs landed together (investigate/undef-flicker):
#
#   1. UNDEF flicker — `CA_UNDEF` global was not pinned against Ruby 3.x
#      compacting GC, so `rval == CA_UNDEF` comparisons in C silently
#      failed after compaction, surfacing as random "can't coerce UNDEF
#      into Integer/Float" TypeErrors in aggregate `rake spec_ai` runs
#      (standalone always green).
#
#   2. CABitfield mask double-free — `Init_ca_obj_bitfield` registered
#      `&carray_data_type` as the mask TypedData, whose dfree dispatches
#      to `ca_free`, while `free_ca_bitfield` also frees `ca->mask`.
#      GC of the Ruby `bf.mask` VALUE triggered double-free → Bus error
#      at the next GC pass.
#
#   3. CABitarray / CAFake — same wrong mask TypedData bug as (2).

class TestMaskViewRegressions < Test::Unit::TestCase

  # --- UNDEF identity must survive GC.compact ----------------------------

  def test_undef_identity_survives_gc_compact
    pre = UNDEF.object_id
    GC.compact
    GC.compact
    assert_equal pre, UNDEF.object_id, "UNDEF must not be relocated by compacting GC"
  end

  def test_store_undef_after_compact
    a = CArray.uint32(4).seq
    a.mask = 0
    GC.compact
    GC.compact
    # If CA_UNDEF were stale, this would fall through to to_i and raise.
    assert_nothing_raised { a[2] = UNDEF }
    assert_equal true, a.is_masked[2]
  end

  # --- CABitfield mask round-trip ---------------------------------------

  def test_bitfield_mask_propagation
    a = CArray.uint32(4).seq
    a.mask = 0
    a[2] = UNDEF
    bf = a.bitfield(0..3)
    assert_true bf.has_mask?
    assert_equal [false, false, true, false], bf.is_masked.to_a
    # Force a GC pass — exercises the (formerly) bogus mask dfree.
    GC.start
    assert_equal [false, false, true, false], bf.mask.to_a
  end

  # --- CAFake mask round-trip -------------------------------------------

  def test_fake_mask_propagation
    a = CArray.int32(4).seq
    a.mask = 0
    a[1] = UNDEF
    f = a.fake(:float64)
    assert_true f.has_mask?
    assert_equal [false, true, false, false], f.is_masked.to_a
    GC.start
    assert_equal [false, true, false, false], f.mask.to_a
  end

  # --- CABitarray mask round-trip ---------------------------------------

  def test_bitarray_mask_propagation
    a = CArray.uint8(4).seq
    a.mask = 0
    a[2] = UNDEF
    ba = a.bitarray
    assert_true ba.has_mask?
    # CABitarray fans each parent byte out into 8 bit slots.
    expected = [[false]*8, [false]*8, [true]*8, [false]*8]
    assert_equal expected, ba.is_masked.to_a
    GC.start
    assert_equal expected, ba.mask.to_a
  end

  # A view whose mask is made while the view is being attached keeps that
  # mask at the view's own attach level, so the mask lets go when the view
  # does.  One level too many left the mask of a selection attached, and it
  # went on reading the buffer it held when the parent's mask changed.
  def test_a_selection_follows_its_parents_mask_after_being_read
    x = CA_INT32([1, 2, 3, 4])
    x[1] = UNDEF
    v = x[CA_BOOLEAN([1, 1, 0, 1])]
    assert_equal [1, UNDEF, 4], v.to_a
    assert_equal false, v.mask.attached?
    x[3] = UNDEF
    assert_equal [1, UNDEF, UNDEF], v.to_a
    x.unmask
    assert_equal [1, 2, 4], v.to_a
  end

  def test_a_shift_follows_its_parents_mask_after_being_read
    x = CA_INT32([1, 2, 3, 4, 5, 6])
    x[1] = UNDEF
    v = x.shift(1)
    assert_equal [0, 1, UNDEF, 3, 4, 5], v.to_a
    x[4] = UNDEF
    assert_equal [0, 1, UNDEF, 3, 4, UNDEF], v.to_a
    x.unmask
    assert_equal [0, 1, 2, 3, 4, 5], v.to_a
  end

end

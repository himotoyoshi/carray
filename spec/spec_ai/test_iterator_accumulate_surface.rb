# Iterator-family `accumulate` surface test.
#
# `accumulate` is the arithmetic sibling of `sum`: the same fold, kept in the
# source's own data type and wrapping at its width, where `sum` answers in the
# type the core promotes to (float64 for an integer source).  It is a required
# member of the CAIterator surface, so all five members provide it, and each is
# the core `CArray#accumulate` lifted to the piece -- the data type, the mask
# handling (a masked cell contributes nothing) and the zero-contribution
# contract (an empty or fully-masked piece is the additive identity 0,
# unmasked) are the core's, unchanged.
#
# This test pins:
#   (a) surface uniformity -- every member answers respond_to?(:accumulate);
#   (b) the value against an independent pure-Ruby per-piece fold, in-type;
#   (c) that the result data type is the SOURCE's, not float64 (the whole point
#       of the spelling), including the int8 wrap that `sum` does not do;
#   (d) masked cells skipped, and an empty piece = 0 unmasked;
#   (e) the boolean lane is XOR parity, as in the core (a boolean stays boolean,
#       so a second `true` has nowhere to carry into);
#   (f) the group member's in-type fold is EXACT for an int64 payload wider than
#       float64's mantissa, where its float64 `sum` is not.

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../ext", __dir__)
require "test/unit"
require "carray"

class TestIteratorAccumulateSurface < Test::Unit::TestCase

  # 2x6 int8, so a per-row fold of the big row wraps int8 and a per-tile one
  # does not -- both cases exercised from one source.
  def src
    CA_INT8([[100, 100, 100, 1, 2, 3],
             [  1,   2,   3, 4, 5, 6]])
  end

  def wrap8 (n)
    n &= 0xff
    n >= 128 ? n - 256 : n
  end

  # ---- (a) surface uniformity -----------------------------------------

  def members (a)
    { slab:        a[nil, :>],
      window:      a.windows(0..0, -1..1),
      block:       a.blocks(1, 3),
      categorical: a.flatten.group_by_category(
                     CA_INT32([0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3]).categorize),
      group:       a[CA_INT32([0, 0]).categorize, nil] }
  end

  def test_every_member_provides_accumulate
    members(src).each do |name, it|
      assert_respond_to it, :accumulate, "#{name} (#{it.class}) lacks #accumulate"
    end
  end

  # ---- (b) + (c) value and data type, against a Ruby fold --------------

  def test_slab_accumulate_is_the_in_type_row_fold
    r = src[nil, :>].accumulate
    assert_equal :int8, r.data_type
    assert_equal [wrap8(306), 21], r.to_a
    # sum is the promoted sibling: same fold, no wrap.
    assert_equal :float64, src[nil, :>].sum.data_type
    assert_equal [306.0, 21.0], src[nil, :>].sum.to_a
  end

  def test_block_accumulate_is_the_in_type_tile_fold
    r = src.blocks(1, 3).accumulate
    assert_equal :int8, r.data_type
    assert_equal [[wrap8(300), 6], [6, 15]], r.to_a
  end

  def test_window_accumulate_is_the_in_type_window_fold
    r = src.windows(0..0, -1..1).accumulate
    assert_equal :int8, r.data_type
    # row 1, window over columns [-1, 0, 1] with an UNDEF margin (:skip default)
    assert_equal [3, 6, 9, 12, 15, 11], r[1, nil].to_a
  end

  def test_categorical_accumulate_is_the_in_type_category_fold
    v = CA_INT8([100, 100, 100, 1, 2, 3])
    g = v.group_by_category(CA_INT32([0, 0, 0, 1, 1, 1]).categorize)
    r = g.accumulate
    assert_equal :int8, r.data_type
    assert_equal [wrap8(300), 6], r.to_a
  end

  def test_group_accumulate_is_the_in_type_group_fold
    g = src[CA_INT32([0, 0]).categorize, nil]     # both rows in group 0
    r = g.accumulate(axis: :group)
    assert_equal :int8, r.data_type
    assert_equal [[101, 102, 103, 5, 7, 9]], r.to_a
    assert_equal :float64, g.sum(axis: :group).data_type
  end

  # ---- (d) masks and the zero-contribution contract --------------------

  def test_masked_cells_contribute_nothing
    a = src.copy
    a[0, 0] = UNDEF                               # drop one of the 100s
    assert_equal [wrap8(206), 21], a[nil, :>].accumulate.to_a
    assert_equal [[wrap8(200), 6], [6, 15]], a.blocks(1, 3).accumulate.to_a
  end

  def test_all_masked_piece_is_the_unmasked_identity
    a = src.copy
    a[0, nil] = UNDEF
    r = a[nil, :>].accumulate
    assert_equal [0, 21], r.to_a
    assert_equal [false, false], r.is_masked.to_a
  end

  def test_empty_group_is_the_unmasked_identity
    v = CA_INT32([[1, 2], [3, 4]])
    # vocabulary 0..2 with nothing classified into 1
    g = v[CA_INT32([0, 2]).categorize(labels: [0, 1, 2]), nil]
    r = g.accumulate(axis: :group)
    assert_equal [[1, 2], [0, 0], [3, 4]], r.to_a
    assert_equal [[false, false]] * 3, r.is_masked.to_a
  end

  # The members that take the core's boundary knobs (block / window; the slab
  # member's reductions take no arguments) pass them straight through.
  def test_min_count_and_fill_value_ride_the_core
    a = src.copy
    a[0, 0] = UNDEF
    assert_equal [[UNDEF, 6], [6, 15]],
                 a.blocks(1, 3).accumulate(min_count: 3).to_a
    assert_equal [[-1, 6], [6, 15]],
                 a.blocks(1, 3).accumulate(min_count: 3, fill_value: -1).to_a
  end

  # ---- (e) the boolean lane is XOR parity ------------------------------

  def test_boolean_accumulate_is_xor_parity
    b = CA_BOOLEAN([[1, 1, 0], [1, 0, 0]])        # row 0 even, row 1 odd
    r = b[nil, :>].accumulate
    assert_equal :boolean, r.data_type
    assert_equal [false, true], r.to_a

    g = b[CA_INT32([0, 1]).categorize, nil].accumulate(axis: :group)
    assert_equal :boolean, g.data_type
    assert_equal [[true, true, false], [true, false, false]], g.to_a
  end

  # ---- (f) exact where the float64 sibling is not ----------------------

  def test_in_type_fold_is_exact_beyond_the_float64_mantissa
    big = 1 << 60
    v   = CA_INT64([[big, 1], [1, big]])

    g = v[CA_INT32([0, 0]).categorize, nil]
    assert_equal [[big + 1, big + 1]], g.accumulate(axis: :group).to_a

    c = CA_INT64([big, 1, big, 1]).group_by_category(
          CA_INT32([0, 0, 1, 1]).categorize)
    assert_equal [big + 1, big + 1], c.accumulate.to_a
    # the float64 sibling loses the low bit -- the reason for the spelling
    assert_equal [big, big], c.sum.to_a
  end

  # ---- object payload rides the core too -------------------------------

  def test_object_payload_stays_object
    o = CA_OBJECT([1, 2, 3, 4])
    g = o.group_by_category(CA_INT32([0, 0, 1, 1]).categorize)
    r = g.accumulate
    assert_equal :object, r.data_type
    assert_equal [3, 7], r.to_a
  end

end

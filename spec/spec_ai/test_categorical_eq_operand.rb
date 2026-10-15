# frozen_string_literal: true
#
# CACategorical#eq / #ne against an array: cell by cell, by label.
#
# Both took one label only, and looked an array up among the labels as if it
# were one; no label is an array, so every cell answered false -- even
# `c.eq(c)`.  The operand is now read the way CArray#eq reads one: a CArray
# cell by cell (a masked cell gives UNDEF, a shape that does not line up
# raises), anything else, a Ruby Array included, as one value.

require "test/unit"
require "carray"
require "carray/categorical"

class TestCategoricalEqOperand < Test::Unit::TestCase

  def cat
    CA_OBJECT(%w[zz aa mm zz]).categorize
  end

  def test_against_itself
    c = cat
    assert_equal [true] * 4,  c.eq(c).to_a
    assert_equal [false] * 4, c.ne(c).to_a
  end

  def test_against_a_categorical_of_another_vocabulary
    other = CA_OBJECT(%w[zz mm aa zz]).categorize(sort_labels: true)
    assert_not_equal cat.labels, other.labels
    assert_equal [true, false, false, true], cat.eq(other).to_a
    assert_equal [false, true, true, false], cat.ne(other).to_a
    assert_equal [true, false, false, true], cat.eq(cat.reverse).to_a
  end

  def test_against_an_object_array
    assert_equal [true, false, false, false], cat.eq(CA_OBJECT(%w[zz mm aa qq])).to_a
    assert_equal [true, true, true, true],
                 cat.eq(CArray.const_string(%w[zz aa mm zz])).to_a
  end

  def test_a_masked_cell_on_either_side_gives_undef
    m = CA_OBJECT(%w[zz mm aa zz])
    m[1] = UNDEF
    assert_equal [true, UNDEF, false, true], cat.eq(m).to_a
    excluded = CA_OBJECT(["zz", UNDEF, "mm", "zz"]).categorize
    assert_equal [true, UNDEF, true, true], cat.eq(excluded).to_a
    assert_equal [true, UNDEF, true, true], excluded.eq(cat).to_a
  end

  def test_views_and_shapes
    c = cat
    assert_equal [false, false], c[1..2].eq(c[2..3]).to_a
    assert_equal [[true, true], [true, true]],
                 c.reshape(2, 2).eq(CA_OBJECT(%w[zz aa mm zz]).reshape(2, 2)).to_a
    assert_raise(ArgumentError) { c.eq(CA_OBJECT(%w[zz aa])) }
  end

  def test_a_categorical_with_no_labels
    empty = CA_OBJECT([UNDEF, UNDEF]).categorize
    assert_equal [UNDEF, UNDEF], cat[0..1].eq(empty).to_a
    assert_equal [UNDEF, UNDEF], empty.eq(cat[0..1]).to_a
  end

  # A scalar, and a Ruby Array, are one label, as CArray#eq takes them.
  def test_one_label
    assert_equal [true, false, false, true], cat.eq("zz").to_a
    assert_equal [false] * 4, cat.eq("qq").to_a
    assert_equal [false] * 4, cat.eq(%w[zz]).to_a
    assert_equal CA_OBJECT(%w[zz aa mm zz]).eq(%w[zz]).to_a, cat.eq(%w[zz]).to_a
  end

end

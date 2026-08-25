# Test for the value-hash discovery family on boolean arrays.
#
# Boolean storage is uint8 (values 0/1, UNDEF via mask), so the discovery
# family routes boolean through the uint8 numeric lane of fz_hash: distinct
# keys are at most two, the hash never grows, and every lookup is O(1). The
# level / value / mode output keeps the source dtype (boolean); counts and
# nunique stay integer as for any dtype.
#
# Members exercised: unique, value_counts, nunique, mask_duplicates, is_mode,
# mode, categorize (factorize_appearance), is_in, intersection, union,
# difference. Each raised a "dtype required" error for boolean before the
# uint8 lane was wired.

require "test/unit"
require "carray"

class TestBooleanDiscovery < Test::Unit::TestCase

  def setup
    # true=3, false=2, first-appearance order true then false
    @b = CA_BOOLEAN([true, false, true, true, false])
  end

  def test_unique_keeps_boolean_dtype_and_order
    u = @b.unique
    assert_equal CA_BOOLEAN, u.data_type
    assert_equal [true, false], u.to_a               # appearance order: true, false
    assert_equal [false, true], @b.unique(sort: true).to_a
  end

  def test_unique_single_value
    assert_equal [true], CA_BOOLEAN([true, true, true]).unique.to_a
  end

  def test_value_counts
    levels, counts = @b.value_counts
    assert_equal CA_BOOLEAN, levels.data_type
    assert_equal [true, false], levels.to_a
    assert_equal CA_INT64, counts.data_type
    assert_equal [3, 2], counts.to_a
  end

  def test_nunique
    assert_equal 2, @b.nunique
    assert_equal 1, CA_BOOLEAN([true, true]).nunique
  end

  def test_nunique_per_axis
    m = CA_BOOLEAN([[true, false, true], [false, false, false]])
    assert_equal [2, 1], m.nunique(axis: 1).to_a
  end

  def test_mask_duplicates_masks_later_occurrences
    # first true (0) and first false (1) kept; the rest masked out
    md = @b.mask_duplicates
    assert_equal CA_BOOLEAN, md.data_type
    assert_equal [false, false, true, true, true], md.mask.to_a
    assert_equal true,  md[0]      # boolean scalar access -> Ruby true/false
    assert_equal false, md[1]
  end

  def test_is_mode
    # modal value is true (count 3); every true cell marked
    assert_equal [true, false, true, true, false], @b.is_mode.to_a
  end

  def test_mode
    m = @b.mode
    assert_equal CA_BOOLEAN, m.data_type
    assert_equal [true], m.to_a
  end

  def test_mode_tie_marks_both
    # true=2, false=2 -> both modal
    assert_equal [false, true], CA_BOOLEAN([true, false, true, false]).mode.to_a.sort_by { |b| b ? 1 : 0 }
  end

  def test_categorize
    cat = @b.categorize
    assert_equal 2, cat.labels.to_a.size
  end

  def test_is_in
    assert_equal [true, false, true, true, false], @b.is_in(CA_BOOLEAN([true])).to_a
    assert_equal [false, true, false, false, true], @b.is_in(CA_BOOLEAN([false])).to_a
  end

  def test_set_operations
    c = CA_BOOLEAN([false, false])
    assert_equal [false],    @b.intersection(c).to_a   # common: false
    assert_equal [true, false], @b.union(c).to_a
    assert_equal [true],    @b.difference(c).to_a      # in self, not in c: true
  end

  def test_all_masked_unique_is_empty
    a = CA_BOOLEAN([true, false])
    a[nil] = UNDEF
    assert_equal [], a.unique.to_a
  end
end

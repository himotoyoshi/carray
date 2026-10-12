# ----------------------------------------------------------------------------
#
#  spec_ai/test_categorical_categorize.rb
#
#  A CACategorical categorizes by its labels, as any key array does: the
#  categories are the labels that occur, in the order they first appear
#  (or sorted with sort_labels:), and a masked cell is excluded.  An unused
#  category of the source does not carry over.  CAFrame#group_by reaches
#  this with a categorical key column.
#
# ----------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestCategoricalCategorize < Test::Unit::TestCase

  def source
    CACategorical.from_codes(CA_UINT8([2, 0, 2, 1]), %w[x y z unused])
  end

  def test_same_as_categorizing_the_labels
    c = source
    r = c.categorize
    o = CA_OBJECT(c.to_a).categorize
    assert_kind_of CACategorical, r
    assert_equal o.labels, r.labels
    assert_equal o.codes.to_a, r.codes.to_a
    assert_equal c.to_a, r.to_a
  end

  def test_unused_categories_do_not_carry_over
    assert_equal %w[z x y], source.categorize.labels
  end

  def test_masked_cell_is_excluded
    s = CA_OBJECT(%w[b a b c])
    s[2] = UNDEF
    r = s.categorize.categorize
    assert_equal %w[b a c], r.labels
    assert_equal ["b", "a", UNDEF, "c"], r.to_a
  end

  def test_sort_labels_and_labels
    assert_equal %w[x y z], source.categorize(sort_labels: true).labels
    r = source.categorize(labels: %w[z y])
    assert_equal %w[z y], r.labels
    assert_equal ["z", UNDEF, "z", "y"], r.to_a
  end

  def test_frame_group_by_a_categorical_column
    df = CAFrame.new("k" => CA_OBJECT(%w[b a b a c]).categorize,
                     "v" => CA_FLOAT64([1, 2, 3, 4, 5]))
    g = df.group_by("k")
    assert_equal %w[b a c], g.labels
    r = g.mean
    assert_kind_of CACategorical, r.index
    assert_equal %w[b a c], r.index.to_a
    assert_equal [2.0, 3.0, 5.0], r["v"].to_a
    assert_equal [2, 2, 1], g.aggregate("n" => ["v", :count]).then { |f| f["n"].to_a }
  end

  def test_frame_group_by_with_a_categorical_component
    df = CAFrame.new("k" => CA_OBJECT(%w[b a b a]).categorize,
                     "j" => CA_INT32([1, 1, 1, 2]),
                     "v" => CA_FLOAT64([1, 2, 3, 4]))
    assert_equal [2.0, 2.0, 4.0], df.group_by("k", "j").mean["v"].to_a
  end

end

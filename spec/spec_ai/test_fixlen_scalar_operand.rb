# A String compared against a fixlen array is a value of that array's cell
# width.
#
# ca_value_to_data_type answers CA_OBJECT for a String, so the operand
# became an object scalar and the comparison ran down the object lane: an
# rb_funcall of String#== per cell, against the cell's NUL-padded text.
# A fixlen array pads a short String on write -- `a[i] = "be"` stores
# "be\0\0\0" -- so an array did not compare equal to the string it was
# written from, reported itself *greater* than it, and took 30x longer
# doing so than the memcmp lane the fixlen comparison bodies provide
# (200k cells: 10.2 ms, against 0.35 ms for the same scan in #search).
#
# Everything else about the array already treated a scalar as a cell
# value: store, search, count, bsearch and locate_addr all pad it.  The
# operand is now built at the receiver's width, which puts the comparison
# family on that side too and restores trichotomy -- exactly one of
# lt / eq / gt per cell.
#
# Two fixlen *arrays* of different widths still compare as the
# variable-width byte strings the comparison bodies implement, and a
# non-String operand (a Regexp for #match) keeps its own coercion: it is
# asking about the bytes rather than standing in for them.
#
# CAFixlenString was never affected -- its scalar-to-storage hook builds
# the query at the cell width already, which is why a Face and its own
# storage disagreed.

require 'test/unit'
require 'carray'

class TestFixlenScalarOperand < Test::Unit::TestCase

  def setup
    @a = CArray.new(CA_FIXLEN, [3], bytes: 5)
    %w[alpha be alpha].each_with_index { |w, i| @a[i] = w }
  end

  def test_a_cell_equals_the_string_it_was_written_from
    assert_equal ["alpha", "be\0\0\0", "alpha"], @a.to_a
    assert_equal [false, true, false], @a.eq("be").to_a
    assert_equal [true, false, true],  @a.ne("be").to_a
  end

  def test_exactly_one_of_lt_eq_gt_holds_per_cell
    lt, eq, gt = @a.lt("be"), @a.eq("be"), @a.gt("be")
    3.times do |i|
      assert_equal 1, [lt[i], eq[i], gt[i]].count(true), "cell #{i}"
    end
  end

  def test_the_full_comparison_family
    assert_equal [true,  false, true],  @a.lt("be").to_a
    assert_equal [false, false, false], @a.gt("be").to_a
    assert_equal [true,  true,  true],  @a.le("be").to_a
    assert_equal [false, true,  false], @a.ge("be").to_a
  end

  def test_the_indexer_selects_the_cell
    assert_equal ["be\0\0\0"], @a[:eq, "be"].to_a
  end

  # The padded spelling and the cell's own value were always accepted;
  # they must keep answering the same.
  def test_the_padded_spellings_agree
    assert_equal @a.eq("be").to_a, @a.eq("be\0\0\0").to_a
    assert_equal @a.eq("be").to_a, @a.eq(@a[1]).to_a
  end

  # The comparison family now agrees with the families that always padded.
  def test_it_agrees_with_search_and_count
    assert_equal 1, @a.search("be")
    assert_equal 1, @a.count("be")
    assert_equal 1, @a.eq("be").count(true)
  end

  # A query wider than the cell truncates, which is what store does with
  # the same String -- the two stay consistent either way.
  def test_an_over_wide_query_truncates_as_store_does
    b = CArray.new(CA_FIXLEN, [1], bytes: 5)
    b[0] = "toolong"
    assert_equal "toolo", b[0]
    assert_equal [true], b.eq("toolong").to_a
  end

  # Two arrays are two byte strings, not a value and its type.
  def test_two_fixlen_arrays_of_different_widths_are_unchanged
    a5 = CArray.new(CA_FIXLEN, [2], bytes: 5).tap { |a| a[0] = "be"; a[1] = "zz" }
    a2 = CArray.new(CA_FIXLEN, [2], bytes: 2).tap { |a| a[0] = "be"; a[1] = "zz" }
    assert_equal [false, false], a5.eq(a2).to_a
    assert_equal [true,  true],  a5.gt(a2).to_a
  end

  # A Regexp asks about the bytes rather than standing in for them.
  def test_a_regexp_operand_keeps_its_own_coercion
    assert_equal [true, false, true], @a.match(/^alpha/).to_a
  end

  def test_the_face_is_unchanged
    fx = CArray.fixlen_string(%w[alpha be alpha])
    assert_equal [false, true, false], fx.eq("be").to_a
    assert_equal [true, false, true],  fx.lt("be").to_a
  end

  def test_other_data_types_are_untouched
    assert_equal [false, true, false], CA_INT32([1, 2, 3]).eq(2).to_a
    assert_equal [true, false],        CA_FLOAT64([1.0, 2.0]).lt(1.5).to_a
    assert_equal [false, true],        CA_OBJECT(%w[a b]).eq("b").to_a
    assert_equal [true, false],        CArray.boolean(2) { |i| i.zero? }.eq(true).to_a
  end

end

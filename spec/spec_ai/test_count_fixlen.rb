# count(v) on a fixlen array.
#
# A fixlen cell is a runtime-width byte blob with no scalar C type, so the
# reduce DSL's value_arg -- which casts the query with NUM2LL / NUM2DBL --
# had nothing to cast it to, and count_equal was declared over the numeric
# types only.  Of the three string Faces that left CAFixlenString as the
# one that could be searched but not counted.
#
# The bespoke fixlen slab walk (the one min / max / argmin / argmax already
# use, ordering cells by memcmp) gains a counting mode, and the dispatcher
# packs the query with rb_ca_obj2ptr the way the search family does.  That
# packing is what makes a short query NUL-pad to the cell width: composing
# this out of `eq` would not have -- raw_fixlen.eq("a") against a 4-byte
# cell holding "a\0\0\0" is false -- besides costing 65x more.

require 'test/unit'
require 'carray'

class TestCountFixlen < Test::Unit::TestCase

  def fixlen (words, bytes)
    a = CArray.new(CA_FIXLEN, [words.size], bytes: bytes)
    words.each_with_index { |w, i| a[i] = w }
    a
  end

  def test_counts_a_value
    a = CArray.fixlen_string(%w[a b a c a])
    assert_equal 3, a.count("a")
    assert_equal 1, a.count("b")
    assert_equal 0, a.count("z")
  end

  # The query is packed to the cell width, so a short String matches a
  # NUL-padded cell.  (`eq` does not do this, which is why count is not
  # built on it.)
  def test_a_short_query_is_padded_to_the_cell_width
    a = fixlen(%w[a b a c a], 4)
    assert_equal 3, a.count("a")
    assert_equal 3, a.count("a\0\0\0")
    assert_equal 1, a.count("b")
  end

  def test_along_an_axis
    a = CArray.fixlen_string(%w[a b a a]).reshape(2, 2)
    assert_equal [1, 2], a.count("a", axis: 1).to_a
    assert_equal [[1], [2]], a.count("a", axis: 1, keep_axis: true).to_a
  end

  def test_masked_cells_do_not_count
    a = CArray.fixlen_string(["a", nil, "a"])
    assert_equal 2, a.count("a")
    assert_equal 2, a.count            # unmasked cells
    assert_equal 1, a.count(UNDEF)     # mask-state count
  end

  # A count over no cells is 0, the additive identity -- not UNDEF.  An
  # explicit min_count: is the way to ask for UNDEF instead.
  def test_nothing_to_count_is_zero
    assert_equal 0, CArray.fixlen_string([nil, nil]).count("a")
    assert_equal 0, CArray.fixlen_string([]).count("a")
    assert_equal UNDEF, CArray.fixlen_string([nil, nil]).count("a", min_count: 1)
  end

  def test_a_wider_cell
    a = fixlen(%w[alpha beta alpha], 8)
    assert_equal 2, a.count("alpha")
    assert_equal 1, a.count("beta")
  end

  # The other modes of the same bespoke walk keep working.
  def test_the_extrema_on_the_same_walk
    a = CArray.fixlen_string(%w[pear apple fig])
    assert_equal "apple", a.min
    assert_equal "pear",  a.max
    assert_equal 1, a.min_index
    assert_equal 0, a.max_index
  end

  def test_the_other_string_faces_agree
    w = %w[a b a c a]
    assert_equal 3, CArray.fixlen_string(w).count("a")
    assert_equal 3, CArray.const_string(w).count("a")
    assert_equal 3, CArray.string(w).count("a")
  end

end

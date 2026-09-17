# CAString declares COMPARABLE, so the search half of the ordering gate is
# open to it.
#
# The gate is two flags on different axes (docs/authoring/FaceOrderingSearch.md):
# ORDERABLE says "my storage order is my surface order" and opens sort;
# COMPARABLE says "an external value compares against my storage directly"
# and opens search.  CAString had only the first, with a comment reading
# "COMPARABLE is left off for now; ordered search (bsearch) is a later
# phase" -- so a string column could be sorted but not searched, while
# CAConstString (which cannot take the gate at all, its storage being byte
# offsets) answered search and count natively.  The two string Faces
# disagreed about which questions a string column takes.
#
# Both claims hold by construction here: a storage cell IS the Ruby String
# the surface shows.  There is no unit to reconcile, which is what stops
# CATime at ORDERABLE.
#
# The Face is transparent, so the reference is the object array underneath:
# whatever that answers, the Face answers.

require 'test/unit'
require 'carray'

class TestCAStringComparable < Test::Unit::TestCase

  W = %w[apple fig kiwi pear].freeze

  def setup
    @st = CArray.string(W)     # sorted, as bsearch requires
    @ob = CA_OBJECT(W)
  end

  # The flags are not exposed to Ruby, so read them where they show: a Face
  # that is only ORDERABLE sorts and refuses to be searched.
  def test_it_is_both_sortable_and_searchable
    assert_equal true, @st.face?
    assert_equal %w[apple fig kiwi pear], @st.sort.to_a   # ORDERABLE
    assert_equal 1, @st.bsearch("fig")                    # COMPARABLE
  end

  def test_ordered_search
    assert_equal 1, @st.bsearch("fig")
    assert_equal 1, @st.bsearch_addr("fig")
    assert_nil      @st.bsearch("plum")
  end

  def test_exact_search
    assert_equal 1, @st.search("fig")
    assert_equal 3, @st.search("pear")
    assert_nil      @st.search("plum")
  end

  def test_count_a_value
    assert_equal 2, CArray.string(%w[a b a]).count("a")
    assert_equal 1, CArray.string(%w[a b a]).count("b")
    assert_equal 0, CArray.string(%w[a b a]).count("z")
  end

  def test_locate_addr
    assert_equal [UNDEF, 0, UNDEF, 1],
                 @st.locate_addr(CArray.string(%w[fig pear])).to_a
  end

  # Whatever the storage answers, the Face answers -- that is the whole
  # claim the flags make.
  MEMBERS = {
    "bsearch"      => ->(a) { a.bsearch("fig") },
    "bsearch_addr" => ->(a) { a.bsearch_addr("fig") },
    "search"       => ->(a) { a.search("fig") },
    "count(v)"     => ->(a) { a.count("fig") },
    "is_in"        => ->(a) { a.is_in(%w[fig plum]).to_a },
    "intersection" => ->(a) { a.intersection(%w[fig plum]).to_a },
    "union"        => ->(a) { a.union(%w[plum]).to_a },
    "difference"   => ->(a) { a.difference(%w[fig]).to_a },
  }.freeze

  def test_the_face_answers_what_its_storage_answers
    MEMBERS.each do |name, f|
      assert_equal f.call(@ob), f.call(@st), "#{name} disagrees with the object storage"
    end
  end

  def test_string_valued_set_results_stay_a_string_face
    assert_kind_of CAString, @st.union(%w[plum])
    assert_kind_of CAString, @st.intersection(%w[fig])
  end

  # A query the column cannot be searched against is still refused.
  def test_a_masked_cell_is_not_a_match
    a = CArray.string(%w[a b c])
    a[1] = UNDEF
    assert_nil a.search("b")
  end

  # Sorting, which ORDERABLE already opened, is untouched.
  def test_sort_still_works
    assert_equal %w[apple fig kiwi pear], CArray.string(%w[pear apple fig kiwi]).sort.to_a
  end

end

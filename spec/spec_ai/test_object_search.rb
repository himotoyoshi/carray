require_relative "../../lib/carray"
require "test/unit"

# PROPOSAL_MKKERNEL_OBJECT_DTYPE_BRANCH Phase 4: search family for
# CA_OBJECT — bsearch / search / bsearch_addr / search_addr.
#
# CA_OBJECT branch:
#   equality: rb_equal(v, query_val)   (= Ruby `==`)
#   ordering: rb_funcall(v, :<=>, query_val)
#   nearest:  query_val.distance(v), min by `<`  (PROPOSAL_SEARCH_SEMANTICS_UNIFY
#             "全部" — distance metric moved into _ki so the legacy flat
#             nearest function can be removed; objects must respond to #distance)
# eps is silently ignored (= no meaningful tolerance on arbitrary
# objects); user-supplied `eps:` kwarg is honored only for float source.

class TestObjectSearch < Test::Unit::TestCase
  # ---- bsearch (sorted, ordering) --------------------------------------

  def test_bsearch_int_found
    a = CA_OBJECT([1, 3, 5, 7, 9, 11])
    assert_equal(3, a.bsearch(7))
  end

  def test_bsearch_int_not_found
    a = CA_OBJECT([1, 3, 5, 7, 9, 11])
    assert_nil(a.bsearch(4))
  end

  def test_bsearch_strings
    b = CA_OBJECT(["apple", "banana", "cherry", "date"])
    assert_equal(2, b.bsearch("cherry"))
    assert_nil(b.bsearch("zzz"))
  end

  def test_bsearch_axis
    d = CA_OBJECT([[1, 3, 5], [2, 4, 6]])
    # row 0: 3 at axis-local 1; row 1: 3 not present -> UNDEF (S1)
    assert_equal([1, UNDEF], d.bsearch(3, axis: 1).to_a)
  end

  def test_bsearch_addr_axis
    e = CA_OBJECT([[1, 3, 5], [2, 4, 6]])
    # row 0: 4 not present -> UNDEF; row 1: 4 at axis-local 1 -> flat addr 1*3+1=4
    assert_equal([UNDEF, 4], e.bsearch_addr(4, axis: 1).to_a)
  end

  def test_bsearch_custom_comparable
    cls = Class.new do
      include Comparable
      attr_reader :v
      def initialize(v); @v = v; end
      def <=>(o); @v <=> o.v; end
    end
    g = CA_OBJECT([cls.new(1), cls.new(3), cls.new(5)])
    assert_equal(1, g.bsearch(cls.new(3)))
  end

  def test_bsearch_raises_on_masked_self
    # mask_self: :raise — bsearch assumes sorted invariant, mask breaks it.
    a = CA_OBJECT([1, 3, 5, 7])
    a[1] = UNDEF
    assert_raise(RuntimeError) { a.bsearch(3, axis: 0) }
  end

  # ---- search (linear, mask: skip, eps ignored for :object) ------------

  def test_search_int_found
    c = CA_OBJECT([5, 3, 1, 4, 2])
    assert_equal(3, c.search(4))
  end

  def test_search_skips_masked
    c = CA_OBJECT([5, 3, 1, 4, 2])
    c[2] = UNDEF
    assert_nil(c.search(1))   # the only 1 is masked
  end

  def test_search_strings
    b = CA_OBJECT(["foo", "bar", "baz"])
    assert_equal(1, b.search("bar"))
  end

  def test_search_addr_axis
    d = CA_OBJECT([[10, 20, 30], [40, 50, 60]])
    # row 0: 20 at flat 1; row 1: 50 at flat 4
    r = d.search_addr(20, axis: 1).to_a
    assert_equal(1, r[0])
    assert_equal(UNDEF, r[1])  # 20 not in row 1 -> UNDEF (S1)
  end

  # ---- search_nearest (distance metric via #distance) ------------------

  # Point with a #distance method (= the contract the object-nearest branch
  # uses, mirroring the legacy flat search_nearest).
  def point_class
    Class.new do
      attr_reader :v
      def initialize(v); @v = v; end
      def distance(o); (@v - o.v).abs; end
    end
  end

  def test_search_nearest_object_1d
    pc = point_class
    arr = CA_OBJECT([pc.new(0), pc.new(10), pc.new(20), pc.new(30)])
    assert_equal(1, arr.search_nearest(pc.new(13)))   # nearest to 13 is 10
    assert_equal(3, arr.search_nearest(pc.new(99)))   # nearest is 30
  end

  def test_search_nearest_object_axis_per_row
    pc = point_class
    g = CA_OBJECT([pc.new(0), pc.new(10), pc.new(20),
                   pc.new(100), pc.new(110), pc.new(120)]).reshape(2, 3)
    r = g.search_nearest(pc.new(13), axis: 1)
    assert_equal([1, 0], r.to_a)
  end

  def test_search_nearest_object_all_masked_row_undef
    pc = point_class
    g = CA_OBJECT([pc.new(0), pc.new(10), pc.new(20),
                   pc.new(100), pc.new(110), pc.new(120)]).reshape(2, 3)
    g.mask = 0
    3.times { |j| g[1, j] = UNDEF }
    r = g.search_nearest(pc.new(13), axis: 1)
    assert_equal([1, UNDEF], r.to_a)   # masked-all row -> UNDEF (S1)
    assert_equal([false, true], r.is_masked.to_a)
  end

  def test_search_eps_ignored_for_object
    # CA_OBJECT uses exact equality regardless of eps (= 3rd positional
    # arg in axis form).  Even with a wide eps, a non-exact value
    # returns no-match (UNDEF) rather than a fuzzy match.
    a = CA_OBJECT([[1.0, 2.0, 3.0]])
    r = a.search(2.0, 0.5, axis: 1).to_a
    assert_equal([1], r)
    r = a.search(2.4, 0.5, axis: 1).to_a
    assert_equal([UNDEF], r)
  end
end

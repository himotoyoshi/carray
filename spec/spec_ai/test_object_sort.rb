require_relative "../../lib/carray"
require "test/unit"

# PROPOSAL_MKKERNEL_OBJECT_DTYPE_BRANCH Phase 2: sort family with
# CA_OBJECT source.  Covers sort_index / sort / partition_index /
# rank_index + axis variants + non-Numeric Comparable (String) + mixed
# Numeric + custom class.

class TestObjectSort < Test::Unit::TestCase
  def test_sort_index_basic
    a = CA_OBJECT([3, 1, 4, 1, 5, 9, 2, 6])
    # stable: ties on '1' preserve original order
    assert_equal([1, 3, 6, 0, 2, 4, 7, 5], a.sort_index.to_a)
  end

  def test_sort_returns_sorted_view
    a = CA_OBJECT([3, 1, 4, 1, 5, 9, 2, 6])
    assert_equal([1, 1, 2, 3, 4, 5, 6, 9], a.sort.to_a)
  end

  def test_sort_strings
    b = CA_OBJECT(["foo", "bar", "baz"])
    assert_equal(["bar", "baz", "foo"], b.sort.to_a)
    assert_equal([1, 2, 0], b.sort_index.to_a)
  end

  def test_sort_mixed_numeric
    c = CA_OBJECT([1, 2.5, Rational(3, 2)])
    assert_equal([0, 2, 1], c.sort_index.to_a)
    assert_equal([1, Rational(3, 2), 2.5], c.sort.to_a)
  end

  def test_sort_index_axis
    d = CA_OBJECT([[3, 1, 2], [5, 4, 6]])
    assert_equal([[1, 2, 0], [1, 0, 2]], d.sort_index(axis: 1).to_a)
  end

  def test_sort_axis
    d = CA_OBJECT([[3, 1, 2], [5, 4, 6]])
    s = d.sort(axis: 1)
    assert_equal([[1, 2, 3], [4, 5, 6]], s.to_a)
    # sort(axis:) goes through sort_addr_ki's object dialect + ca_remap_new
    # (same view path as numeric / fixlen), so this is a CARemap view, not
    # an eager entity.
    assert_equal(CARemap, s.class)
  end

  def test_sort_axis_masked_input_clusters_to_masked_position
    d = CA_OBJECT([[3, 1, 2], [5, 4, 6]])
    d[0, 1] = UNDEF                             # row 0: [3, UNDEF, 2]
    s = d.sort(axis: 1)
    assert_equal([2, 3, UNDEF], s[0, nil].to_a)
    assert_equal([false, false, true], s[0, nil].mask.to_a)

    s_first = d.sort(axis: 1, masked_position: :first)
    assert_equal([UNDEF, 2, 3], s_first[0, nil].to_a)
    assert_equal([true, false, false], s_first[0, nil].mask.to_a)
  end

  def test_partition_index
    e = CA_OBJECT([5, 3, 1, 4, 2])
    r = e.partition_index(2).to_a
    # position kth=2 must hold the 3rd-smallest (= original idx 1, value 3)
    assert_equal(1, r[2])
    # left of kth indexes values <= 3; right indexes values >= 3
    e_arr = e.to_a
    r[0..1].each { |idx| assert(e_arr[idx] <= 3) }
    r[3..4].each { |idx| assert(e_arr[idx] >= 3) }
  end

  def test_rank_index
    e = CA_OBJECT([5, 3, 1, 4, 2])
    assert_equal([4, 2, 0, 3, 1], e.rank_index.to_a)
  end

  def test_sort_uncomparable_raises
    f = CA_OBJECT([1, "two", 3])
    assert_raise(ArgumentError) { f.sort }
  end

  def test_sort_custom_comparable
    cls = Class.new do
      include Comparable
      attr_reader :v
      def initialize(v); @v = v; end
      def <=>(o); @v <=> o.v; end
    end
    objs = [cls.new(3), cls.new(1), cls.new(2)]
    g = CA_OBJECT(objs)
    assert_equal([1, 2, 0], g.sort_index.to_a)
  end

  def test_sort_kind_stable
    # stable kind: gives the same result as default for our tie-break-by-idx
    # cmp; mainly verifies the `kind: :stable` path doesn't break.
    a = CA_OBJECT([3, 1, 4, 1, 5, 9, 2, 6])
    assert_equal([1, 1, 2, 3, 4, 5, 6, 9], a.sort(kind: :stable).to_a)
  end
end

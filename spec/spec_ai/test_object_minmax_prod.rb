require_relative "../../lib/carray"
require "test/unit"

# PROPOSAL_MKKERNEL_OBJECT_DTYPE_BRANCH Phase 3: min / max / prod with
# CA_OBJECT source via mkkernel :object dtype branch.  min / max use
# Qundef sentinel + "first cell as init" pattern (Q1 case A) since no
# identity value exists for arbitrary Comparable.

class TestObjectMinMaxProd < Test::Unit::TestCase
  def test_min_basic
    a = CA_OBJECT([3, 1, 4, 1, 5, 9, 2, 6])
    assert_equal(1, a.min)
  end

  def test_max_basic
    a = CA_OBJECT([3, 1, 4, 1, 5, 9, 2, 6])
    assert_equal(9, a.max)
  end

  def test_prod_basic
    a = CA_OBJECT([1, 2, 3, 4])
    assert_equal(24, a.prod)
  end

  def test_min_strings
    b = CA_OBJECT(["foo", "bar", "baz", "qux"])
    assert_equal("bar", b.min)
  end

  def test_max_strings
    b = CA_OBJECT(["foo", "bar", "baz", "qux"])
    assert_equal("qux", b.max)
  end

  def test_min_axis
    c = CA_OBJECT([[3, 1, 2], [6, 4, 5]])
    assert_equal([1, 4], c.min(axis: 1).to_a)
  end

  def test_max_axis
    c = CA_OBJECT([[3, 1, 2], [6, 4, 5]])
    assert_equal([3, 6], c.max(axis: 1).to_a)
  end

  def test_min_with_mask
    d = CA_OBJECT([5, 1, 3, 7])
    d[1] = UNDEF   # 1 is masked
    assert_equal(3, d.min)
  end

  def test_min_all_masked_slab
    e = CA_OBJECT([[1, 2, 3], [4, 5, 6]])
    e[0, nil] = UNDEF
    r = e.min(axis: 1)
    assert_equal(true, r.mask[0])
    assert_equal(false, r.mask[1])
    assert_equal(4, r[1])
  end

  def test_prod_mixed_numeric
    f = CA_OBJECT([2, Rational(3, 2)])
    assert_equal(Rational(3, 1), f.prod)
  end

  def test_min_custom_comparable
    cls = Class.new do
      include Comparable
      attr_reader :v
      def initialize(v); @v = v; end
      def <=>(o); @v <=> o.v; end
      def ==(o); o.is_a?(self.class) && @v == o.v; end
    end
    objs = [cls.new(3), cls.new(1), cls.new(2)]
    g = CA_OBJECT(objs)
    assert_equal(1, g.min.v)
    assert_equal(3, g.max.v)
  end

  def test_prod_fill_value
    # ERI.1: an all-masked slab is now the multiplicative identity 1 (not
    # UNDEF) under default min_count, so fill_value has nothing to fill.
    # Use min_count: 1 to force a genuine UNDEF that fill_value replaces.
    h = CA_OBJECT([[2, 3], [4, 5]])
    h[0, nil] = UNDEF
    r = h.prod(axis: 1, min_count: 1, fill_value: -1)
    assert_equal([-1, 20], r.to_a)
    # default: all-masked row -> identity 1, unmasked
    r2 = h.prod(axis: 1)
    assert_equal([1, 20], r2.to_a)
    assert_equal(false, r2.has_mask?)
  end
end

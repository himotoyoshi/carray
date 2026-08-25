require_relative "../../lib/carray"
require "test/unit"

# PROPOSAL_MKKERNEL_OBJECT_DTYPE_BRANCH Phase 5a: cumulative scan
# family for CA_OBJECT — cumsum / cumprod / cummax / cummin.  The
# CA_SLAB_SCAN_T macro is generic over T_LOAD / T_OUT, so VALUE flows
# through directly with rb_funcall(:+) / (:*) / (:>) / (:<) step bodies.
#
# cummax / cummin use Qnil sentinel for "no running aggregate yet" —
# leading all-masked cells of a fiber leak nil into the output rather
# than the numeric T_LIMIT_LO / HI leak.  The masked-cell branch of
# the scan macro writes the current acc verbatim, which for object
# means "running aggregate excluding masked cells" semantics carry
# through identically.
#
# cumcount is :i64 and doesn't reference v (= already works for any
# source).  uniq_scan stays out of scope (= separate path).

class TestObjectCumulative < Test::Unit::TestCase
  def test_cumsum_basic
    a = CA_OBJECT([1, 2, 3, 4])
    assert_equal([1, 3, 6, 10], a.cumsum.to_a)
  end

  def test_cumprod_basic
    a = CA_OBJECT([1, 2, 3, 4])
    assert_equal([1, 2, 6, 24], a.cumprod.to_a)
  end

  def test_cummax_basic
    a = CA_OBJECT([1, 3, 2, 5, 4])
    assert_equal([1, 3, 3, 5, 5], a.cummax.to_a)
  end

  def test_cummin_basic
    a = CA_OBJECT([3, 1, 2, 5, 0])
    assert_equal([3, 1, 1, 1, 0], a.cummin.to_a)
  end

  def test_cumsum_axis
    b = CA_OBJECT([[1, 2, 3], [4, 5, 6]])
    assert_equal([[1, 3, 6], [4, 9, 15]], b.cumsum(axis: 1).to_a)
  end

  def test_cummax_strings
    c = CA_OBJECT(["b", "a", "c", "a"])
    assert_equal(["b", "b", "c", "c"], c.cummax.to_a)
  end

  def test_cummin_strings
    c = CA_OBJECT(["b", "a", "c", "a"])
    assert_equal(["b", "a", "a", "a"], c.cummin.to_a)
  end

  def test_cumsum_with_mask
    # Masked cell preserves current running aggregate (= per 2026-06-03
    # scan macro contract): output reads back the previous acc value.
    d = CA_OBJECT([1, 2, 3, 4, 5])
    d[2] = UNDEF
    assert_equal([1, 3, 3, 7, 12], d.cumsum.to_a)
  end

  def test_cummax_leading_masked_yields_undef
    # cummax / cummin have no identity, so a fiber's running extremum is
    # undefined until its first present cell: leading masked cells are
    # UNDEF (masked), not the Qnil sentinel (3.0 reduction-contract
    # alignment; matches numeric cummax and the axis-group scan family).
    e = CA_OBJECT([1, 2, 3])
    e[0] = UNDEF
    got = e.cummax
    assert_equal([true, false, false], got.mask.to_a)
    assert_equal([UNDEF, 2, 3], got.to_a)
  end

  def test_cummin_leading_masked_yields_undef
    e = CA_OBJECT([3, 2, 1])
    e[0] = UNDEF
    got = e.cummin
    assert_equal([true, false, false], got.mask.to_a)
    assert_equal([UNDEF, 2, 1], got.to_a)
  end

  def test_cumprod_mixed_numeric
    f = CA_OBJECT([1, 2, Rational(3, 2)])
    assert_equal([1, 2, Rational(3, 1)], f.cumprod.to_a)
  end

  def test_cummax_custom_comparable
    cls = Class.new do
      include Comparable
      attr_reader :v
      def initialize(v); @v = v; end
      def <=>(o); @v <=> o.v; end
      def to_s; "C(#{@v})"; end
      def inspect; to_s; end
    end
    g = CA_OBJECT([cls.new(2), cls.new(5), cls.new(3), cls.new(7)])
    vs = g.cummax.to_a.map(&:v)
    assert_equal([2, 5, 5, 7], vs)
  end
end

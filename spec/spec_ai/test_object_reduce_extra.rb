require_relative "../../lib/carray"
require "test/unit"

# PROPOSAL_MKKERNEL_OBJECT_DTYPE_BRANCH Phase 3.5: extended reduce
# family for CA_OBJECT — mean / accumulate / minmax / argmin / argmax
# / argmin_addr / argmax_addr (= min_index / max_index / min_addr /
# max_addr Ruby surface).

class TestObjectReduceExtra < Test::Unit::TestCase
  # ---- mean ------------------------------------------------------------

  def test_mean_integer_uses_ruby_division
    # CA_OBJECT mean keeps Ruby's natural type semantics: Integer / Integer
    # is Integer (truncated).  [3,1,4,1,5,9,2,6].sum = 31, /8 = 3.
    a = CA_OBJECT([3, 1, 4, 1, 5, 9, 2, 6])
    assert_equal(3, a.mean)
  end

  def test_mean_float
    a = CA_OBJECT([1.0, 2.0, 3.0])
    assert_equal(2.0, a.mean)
  end

  def test_mean_mixed_rational
    a = CA_OBJECT([Rational(1, 2), Rational(3, 2)])
    assert_equal(Rational(1, 1), a.mean)
  end

  def test_mean_axis
    c = CA_OBJECT([[3, 1, 2], [6, 9, 3]])
    # Integer division: [2, 6]
    assert_equal([2, 6], c.mean(axis: 1).to_a)
  end

  def test_mean_all_masked_yields_undef
    a = CA_OBJECT([1, 2, 3])
    a[0..2] = UNDEF
    r = a.mean(axis: 0)   # flat or per-axis result; scalar-or-nil
    # all-masked: legacy default returns nil (sentinel form)
    assert(r.nil? || r == UNDEF, "expected nil/UNDEF for all-masked, got #{r.inspect}")
  end

  # ---- accumulate ------------------------------------------------------

  def test_accumulate_preserves_object
    a = CA_OBJECT([1, 2, 3, 4])
    assert_equal(10, a.accumulate)
  end

  def test_accumulate_with_mask
    a = CA_OBJECT([1, 2, 3, 4])
    a[1] = UNDEF
    assert_equal(8, a.accumulate)
  end

  def test_accumulate_mixed_numeric
    a = CA_OBJECT([1, 2.5, Rational(3, 2)])
    assert_equal(5.0, a.accumulate)
  end

  # ---- minmax ----------------------------------------------------------

  def test_minmax_basic
    a = CA_OBJECT([3, 1, 4, 1, 5, 9, 2, 6])
    assert_equal([1, 9], a.minmax)
  end

  def test_minmax_strings
    b = CA_OBJECT(["foo", "bar", "baz"])
    assert_equal(["bar", "foo"], b.minmax)
  end

  def test_minmax_axis
    c = CA_OBJECT([[3, 1, 2], [5, 4, 6]])
    mins, maxs = c.minmax(axis: 1)
    assert_equal([1, 4], mins.to_a)
    assert_equal([3, 6], maxs.to_a)
  end

  def test_minmax_all_masked_slab
    e = CA_OBJECT([[1, 2, 3], [4, 5, 6]])
    e[0, nil] = UNDEF
    mins, maxs = e.minmax(axis: 1)
    assert_equal(true, mins.mask[0])
    assert_equal(true, maxs.mask[0])
    assert_equal(4, mins[1])
    assert_equal(6, maxs[1])
  end

  # ---- min_index / max_index (argmin / argmax) -------------------------

  def test_min_index_basic
    a = CA_OBJECT([3, 1, 4, 1, 5, 9, 2, 6])
    # tie at value 1: stable selection picks first occurrence (idx 1)
    assert_equal(1, a.min_index)
  end

  def test_max_index_basic
    a = CA_OBJECT([3, 1, 4, 1, 5, 9, 2, 6])
    assert_equal(5, a.max_index)
  end

  def test_min_index_strings
    b = CA_OBJECT(["foo", "bar", "baz"])
    assert_equal(1, b.min_index)
  end

  def test_max_index_axis
    c = CA_OBJECT([[3, 1, 2], [5, 4, 6]])
    assert_equal([0, 2], c.max_index(axis: 1).to_a)
  end

  def test_argmin_with_mask
    a = CA_OBJECT([5, 1, 3, 0, 2])
    a[3] = UNDEF   # mask out the actual min
    assert_equal(1, a.min_index)
  end

  # ---- min_addr / max_addr (argmin_addr / argmax_addr) -----------------

  def test_min_addr_axis
    c = CA_OBJECT([[3, 1, 2], [5, 4, 6]])
    # Flat row-major: row 0 spans 0..2, row 1 spans 3..5.
    # Row 0 min at col 1 -> flat 1; row 1 min at col 1 -> flat 4.
    assert_equal([1, 4], c.min_addr(axis: 1).to_a)
  end

  def test_max_addr_flat
    a = CA_OBJECT([3, 1, 9, 4])
    assert_equal(2, a.max_addr)
  end

  # ---- Comparable custom class -----------------------------------------

  def test_argmin_custom_comparable
    cls = Class.new do
      include Comparable
      attr_reader :v
      def initialize(v); @v = v; end
      def <=>(o); @v <=> o.v; end
    end
    g = CA_OBJECT([cls.new(3), cls.new(1), cls.new(2)])
    assert_equal(1, g.min_index)
    assert_equal(0, g.max_index)
  end
end

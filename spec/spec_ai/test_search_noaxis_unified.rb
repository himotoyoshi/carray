# frozen_string_literal: true
#
# PROPOSAL_SEARCH_SEMANTICS_UNIFY S3/S4: the no-axis (flat) search surface
# is now a thin wrapper over the per-axis _ki kernels (flatten + index
# kernel at axis 0).  The legacy hand-written flat scan functions
# (rb_ca_binary_search / rb_ca_linear_search / rb_ca_linear_search_nearest)
# were removed.
#
# These tests pin the unified no-axis contract -- verified equal to the old
# flat behavior before removal (S4 parity):
#
#   non-CArray query -> scalar result (Integer / nil)
#   CArray query     -> query-shaped CArray result (UNDEF on no-match),
#                       for ANY query shape incl. a single-element query.

require "test/unit"
require "carray"

class TestSearchNoaxisUnified < Test::Unit::TestCase

  # ---- bsearch: scalar query -> scalar -------------------------------

  def test_bsearch_scalar_int
    a = CA_INT([10, 20, 30, 40, 50])
    assert_equal 2, a.bsearch(30)
    assert_nil      a.bsearch(35)
  end

  def test_bsearch_scalar_float
    a = CArray.float64(4) { |i| [1.0, 2.0, 3.0, 4.0][i] }
    assert_equal 2, a.bsearch(3.0)
    assert_nil      a.bsearch(3.5)
  end

  def test_bsearch_scalar_object
    a = CA_OBJECT([1, 2, 3, 4, 5])
    assert_equal 2, a.bsearch(3)
    assert_nil      a.bsearch(99)
  end

  def test_bsearch_scalar_fixlen
    a = CA_FIXLEN(%w[ant bee cat dog], bytes: 3)
    assert_equal 2, a.bsearch("cat")
    assert_nil      a.bsearch("zzz")
  end

  # ---- bsearch: CArray query -> query-shaped CArray ------------------

  def test_bsearch_array_query_is_query_shaped
    a = CA_INT([10, 20, 30, 40, 50])
    r = a.bsearch(CA_INT([10, 35, 50]))
    assert_kind_of CArray, r
    assert_equal [0, UNDEF, 4], r.to_a
    assert_equal [false, true, false],     r.is_masked.to_a
  end

  def test_bsearch_2d_query_keeps_shape
    a = CA_INT([10, 20, 30, 40, 50])
    r = a.bsearch(CA_INT([[10, 35], [50, 99]]))
    assert_equal [2, 2], r.dim
    assert_equal [[0, UNDEF], [4, UNDEF]], r.to_a
  end

  # The rev4 A1 single-element collapse must NOT leak into the no-axis
  # surface: a [1] CArray query stays query-shaped ([1] array), not scalar.
  def test_bsearch_single_element_query_stays_array
    a = CA_INT([10, 20, 30, 40, 50])
    r = a.bsearch(CA_INT([30]))
    assert_kind_of CArray, r
    assert_equal [1], r.dim
    assert_equal [2], r.to_a
    # no-match single-element query -> [1] masked
    r2 = a.bsearch(CA_INT([35]))
    assert_kind_of CArray, r2
    assert_equal [UNDEF], r2.to_a
    assert_equal [true],     r2.is_masked.to_a
  end

  # ---- masked self raises (bsearch sorted invariant) -----------------

  def test_bsearch_masked_self_raises
    a = CA_INT([10, 20, 30, 40, 50])
    a.mask = [0, 0, 1, 0, 0]
    assert_raise(RuntimeError) { a.bsearch(30) }
  end

  # ---- search: scalar (parity) + array/fixlen (S3 additive) ----------

  def test_search_scalar_unchanged
    a = CA_INT([5, 3, 1, 4, 2])
    assert_equal 3, a.search(4)
    assert_nil      a.search(99)
  end

  def test_search_eps_scalar
    a = CArray.float64(4) { |i| [1.0, 2.0, 3.0, 4.0][i] }
    assert_equal 1, a.search(2.4, 0.5)   # within eps of 2.0
    assert_nil      a.search(2.4)        # exact: no match
  end

  # S3 additive: no-axis search of a CArray query used to raise TypeError;
  # it now returns a query-shaped result (consistent with bsearch).
  def test_search_array_query_now_supported
    a = CA_INT([5, 3, 1, 4, 2])
    r = a.search(CA_INT([4, 99]))
    assert_equal [3, UNDEF], r.to_a
    assert_equal [false, true],     r.is_masked.to_a
  end

  # S3 additive: no-axis search of fixlen used to raise DataTypeError.
  def test_search_fixlen_now_supported
    a = CA_FIXLEN(%w[dog ant cat bee], bytes: 3)
    assert_equal 2, a.search("cat")
    assert_nil      a.search("zzz")
  end

  # ---- search_nearest: numeric + object distance ---------------------

  def test_search_nearest_scalar_numeric
    a = CA_INT([0, 10, 20, 30])
    assert_equal 1, a.search_nearest(13)   # nearest to 13 is 10
    assert_equal 3, a.search_nearest(99)
  end

  def test_search_nearest_object_distance
    pc = Class.new do
      attr_reader :v
      def initialize(v); @v = v; end
      def distance(o); (@v - o.v).abs; end
    end
    a = CA_OBJECT([pc.new(0), pc.new(10), pc.new(20), pc.new(30)])
    assert_equal 1, a.search_nearest(pc.new(13))
  end
end

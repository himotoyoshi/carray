# frozen_string_literal: true
#
# pair-wise max / min — three flavours, two NaN policies.
#
#   maximum / minimum  NaN-propagate (= NumPy `np.maximum` / `np.minimum`)
#   pmax / pmin        NaN-skip      (CArray legacy, via C99 fmax/fmin)
#   fmax / fmin        NaN-skip      (Ruby aliases of pmax / pmin,
#                                     matches NumPy `np.fmax` / `np.fmin`
#                                     and C library)
#
# Integer / non-NaN: all six produce identical results.  The split only
# matters when an operand is NaN.  See devel/MEMO_GALAPAGOS_ESCAPE.md
# §3 entry for the 3-name design rationale.

require "test/unit"
require "carray"

class TestMaxMinFamily < Test::Unit::TestCase
  NAN = 0.0 / 0.0

  # --- pmax / pmin: NaN-skip (existing behaviour) -----------------

  def test_pmax_nan_skip
    a = CA_FLOAT64([NAN, 1.0, 3.0])
    b = CA_FLOAT64([5.0, NAN, 2.0])
    assert_equal [5.0, 1.0, 3.0], a.pmax(b).to_a
  end

  def test_pmin_nan_skip
    a = CA_FLOAT64([NAN, 1.0, 3.0])
    b = CA_FLOAT64([5.0, NAN, 2.0])
    assert_equal [5.0, 1.0, 2.0], a.pmin(b).to_a
  end

  # --- fmax / fmin: Ruby aliases of pmax / pmin -------------------

  def test_fmax_is_alias_of_pmax
    assert_equal CArray.instance_method(:pmax),
                 CArray.instance_method(:fmax)
  end

  def test_fmin_is_alias_of_pmin
    assert_equal CArray.instance_method(:pmin),
                 CArray.instance_method(:fmin)
  end

  def test_fmax_byte_parity_pmax
    a = CA_FLOAT64([NAN, 1.0, 3.0, -2.0])
    b = CA_FLOAT64([5.0, NAN, 2.0,  0.0])
    assert_equal a.pmax(b).to_a, a.fmax(b).to_a
  end

  def test_fmin_byte_parity_pmin
    a = CA_FLOAT64([NAN, 1.0, 3.0, -2.0])
    b = CA_FLOAT64([5.0, NAN, 2.0,  0.0])
    assert_equal a.pmin(b).to_a, a.fmin(b).to_a
  end

  # --- maximum / minimum: NaN-propagate (NumPy np.maximum) --------

  def test_maximum_nan_propagate
    # If either operand is NaN, result is NaN (NumPy convention).
    a = CA_FLOAT64([NAN, 1.0, 3.0])
    b = CA_FLOAT64([5.0, NAN, 2.0])
    r = a.maximum(b)
    assert r[0].nan?, "NaN in lhs propagates"
    assert r[1].nan?, "NaN in rhs propagates"
    assert_equal 3.0, r[2]
  end

  def test_minimum_nan_propagate
    a = CA_FLOAT64([NAN, 1.0, 3.0])
    b = CA_FLOAT64([5.0, NAN, 2.0])
    r = a.minimum(b)
    assert r[0].nan?
    assert r[1].nan?
    assert_equal 2.0, r[2]
  end

  def test_maximum_no_nan_matches_pmax
    a = CA_FLOAT64([1.0, 5.0, 3.0])
    b = CA_FLOAT64([4.0, 2.0, 3.0])
    assert_equal a.pmax(b).to_a, a.maximum(b).to_a
  end

  def test_minimum_no_nan_matches_pmin
    a = CA_FLOAT64([1.0, 5.0, 3.0])
    b = CA_FLOAT64([4.0, 2.0, 3.0])
    assert_equal a.pmin(b).to_a, a.minimum(b).to_a
  end

  # --- maximum / minimum vs pmax / pmin on NaN: documented split --

  def test_maximum_vs_pmax_on_nan_diverge
    # The core motivation for keeping two kernels: same name, two
    # semantics in two ecosystems.
    a = CA_FLOAT64([NAN, NAN, 3.0])
    b = CA_FLOAT64([5.0, NAN, 2.0])
    refute_equal a.pmax(b).to_a.map { |v| v.nan? ? :nan : v },
                 a.maximum(b).to_a.map { |v| v.nan? ? :nan : v }
  end

  # --- integer / int: identical across all six --------------------

  def test_int_all_six_identical
    a = CA_INT32([1, 5, 3, -2])
    b = CA_INT32([4, 2, 3,  0])
    answers = [
      a.pmax(b).to_a,
      a.fmax(b).to_a,
      a.maximum(b).to_a,
    ].uniq
    assert_equal 1, answers.size
    assert_equal [4, 5, 3, 0], answers[0]

    mins = [a.pmin(b).to_a, a.fmin(b).to_a, a.minimum(b).to_a].uniq
    assert_equal 1, mins.size
    assert_equal [1, 2, 3, -2], mins[0]
  end

  # --- scalar broadcast ------------------------------------------

  def test_maximum_scalar
    a = CA_FLOAT64([1.0, 5.0, 3.0])
    assert_equal [3.0, 5.0, 3.0], a.maximum(3.0).to_a
  end

  def test_minimum_scalar
    a = CA_FLOAT64([1.0, 5.0, 3.0])
    assert_equal [1.0, 3.0, 3.0], a.minimum(3.0).to_a
  end

  # --- mask propagation ------------------------------------------

  def test_maximum_mask
    a = CA_FLOAT64([1.0, 5.0, 3.0])
    a.mask = CA_BOOLEAN([0, 1, 0])
    b = CA_FLOAT64([4.0, 2.0, 0.5])
    r = a.maximum(b)
    assert_equal [false, true, false], r.mask.to_a
    assert_equal 4.0, r[0]
    assert_equal 3.0, r[2]
  end

  # --- 2D / view dispatch ----------------------------------------

  def test_maximum_2d
    m = CArray.float64(2, 3) { |i, j| i * 3 + j }
    n = CArray.float64(2, 3) { |i, j| (2 - i) * 3 + (2 - j) }
    # No NaN -> maximum == pmax
    assert_equal m.pmax(n).to_a, m.maximum(n).to_a
  end

  def test_minimum_through_transpose
    a = CArray.int32(3, 2) { |i, j| i * 2 + j }
    b = CArray.int32(3, 2) { |i, j| 5 - (i * 2 + j) }
    assert_equal a.transpose.pmin(b.transpose).to_a,
                 a.transpose.minimum(b.transpose).to_a
  end

  # --- bang siblings ---------------------------------------------

  def test_pmax_bang_exists
    assert CArray.method_defined?(:pmax!)
    assert CArray.method_defined?(:pmin!)
  end

  def test_maximum_bang_exists
    # `maximum` / `minimum` are first-class binops (not aliases), so
    # the mkkernel binop framework auto-generates the bang siblings.
    assert CArray.method_defined?(:maximum!)
    assert CArray.method_defined?(:minimum!)
  end

  def test_fmax_bang_not_defined
    # fmax / fmin are pure aliases via rb_define_alias; bang is NOT
    # aliased.  Users wanting in-place use `pmax!` / `pmin!` directly.
    refute CArray.method_defined?(:fmax!)
    refute CArray.method_defined?(:fmin!)
  end
end

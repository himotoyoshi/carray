# ---------------------------------------------------------------------------
# spec_ai/test_mkkernel_cmp_p5b4.rb
#
# Phase 5b P.5b.4 — moncmp + bincmp family migration from
# ext/carray_math.rb to ext/mkkernel.rb (MkKernel.moncmp / .bincmp /
# .alias_bincmp).  Pins behavior for predicate kernels (is_nan / is_inf
# / is_finite / eq / ne / gt / lt / ge / le / feq / match / is_kind_of),
# fixlen string comparison, lazy chain through CABinCmp / CAMonCmp,
# and operator alias surface (>, <, >=, <=, =~).
# ---------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path('../../../ext', __FILE__)
$LOAD_PATH.unshift File.expand_path('../../../lib', __FILE__)

require 'test/unit'
require 'carray'

class TestMkKernelCmpP5b4 < Test::Unit::TestCase
  # --- moncmp -------------------------------------------------------------

  def test_is_nan_float
    a = CArray.float64(4); a[] = [1.0, Float::NAN, 0.0, -2.5]
    assert_equal [false, true, false, false], a.is_nan.to_a
  end

  def test_is_nan_integer_always_zero
    a = CArray.int32(3); a[] = [1, 0, -5]
    assert_equal [false, false, false], a.is_nan.to_a
  end

  def test_is_inf
    a = CArray.float64(4); a[] = [1.0, Float::INFINITY, -Float::INFINITY, Float::NAN]
    assert_equal [false, true, true, false], a.is_inf.to_a
  end

  def test_is_finite
    a = CArray.float64(4); a[] = [1.0, Float::INFINITY, Float::NAN, 2.5]
    assert_equal [true, false, false, true], a.is_finite.to_a
  end

  def test_is_finite_integer_always_true
    a = CArray.int32(3); a[] = [1, 0, -5]
    assert_equal [true, true, true], a.is_finite.to_a
  end

  # --- bincmp arithmetic predicates ---------------------------------------

  def setup_pair
    @a = CArray.int32(3); @a[] = [1, 2, 3]
    @b = CArray.int32(3); @b[] = [1, 5, 3]
  end

  def test_eq
    setup_pair
    assert_equal [true, false, true], @a.eq(@b).to_a
  end

  def test_ne
    setup_pair
    assert_equal [false, true, false], @a.ne(@b).to_a
  end

  def test_gt
    setup_pair
    assert_equal [false, false, false], @a.gt(@b).to_a
  end

  def test_lt
    setup_pair
    assert_equal [false, true, false], @a.lt(@b).to_a
  end

  def test_ge
    setup_pair
    assert_equal [true, false, true], @a.ge(@b).to_a
  end

  def test_le
    setup_pair
    assert_equal [true, true, true], @a.le(@b).to_a
  end

  # --- operator aliases ---------------------------------------------------

  def test_gt_operator_alias
    setup_pair
    assert_equal @a.gt(@b).to_a, (@a > @b).to_a
  end

  def test_lt_operator_alias
    setup_pair
    assert_equal @a.lt(@b).to_a, (@a < @b).to_a
  end

  def test_ge_operator_alias
    setup_pair
    assert_equal @a.ge(@b).to_a, (@a >= @b).to_a
  end

  def test_le_operator_alias
    setup_pair
    assert_equal @a.le(@b).to_a, (@a <= @b).to_a
  end

  # --- feq (fuzzy float equality) -----------------------------------------

  def test_feq_strict_equality
    f1 = CArray.float64(2); f1[] = [1.0, 2.0]
    f2 = CArray.float64(2); f2[] = [1.0, 2.0]
    assert_equal [true, true], f1.feq(f2).to_a
  end

  def test_feq_large_diff_unequal
    f1 = CArray.float64(2); f1[] = [1.0, 2.0]
    f2 = CArray.float64(2); f2[] = [1.5, 2.5]
    assert_equal [false, false], f1.feq(f2).to_a
  end

  # --- fixlen comparison --------------------------------------------------

  def test_fixlen_eq
    s1 = CArray.fixlen(3, bytes: 5); s1[] = ["hello", "world", "foo  "]
    s2 = CArray.fixlen(3, bytes: 5); s2[] = ["hello", "WORLD", "foo  "]
    assert_equal [true, false, true], s1.eq(s2).to_a
  end

  def test_fixlen_lt
    s1 = CArray.fixlen(3, bytes: 5); s1[] = ["aaa  ", "zzz  ", "mmm  "]
    s2 = CArray.fixlen(3, bytes: 5); s2[] = ["bbb  ", "yyy  ", "mmm  "]
    assert_equal [true, false, false], s1.lt(s2).to_a
  end

  def test_match_fixlen_with_regex
    s = CArray.fixlen(3, bytes: 5); s[] = ["hello", "world", "foo  "]
    assert_equal [true, true, true], s.match(/o/).to_a
    assert_equal [false, false, false], s.match(/z/).to_a
  end

  def test_match_via_regex_operator
    s = CArray.fixlen(3, bytes: 5); s[] = ["abc  ", "xyz  ", "def  "]
    assert_equal [true, false, true], (s =~ /[ad]/).to_a
  end

  # --- is_kind_of (object only) ------------------------------------------

  def test_is_kind_of
    obj = CArray.object(3); obj[] = [1, "str", 3.14]
    assert_equal [false, true, false], obj.is_kind_of(String).to_a
    assert_equal [false, false, true], obj.is_kind_of(Float).to_a
    assert_equal [true, false, false], obj.is_kind_of(Integer).to_a
  end

  # --- lazy chain through CABinCmp / CAMonCmp ----------------------------

  def test_lazy_is_nan_returns_camoncmp
    a = CArray.float64(3); a[] = [1.0, Float::NAN, 2.0]
    lazy = a.lazy.is_nan
    assert_kind_of CAMonCmp, lazy
    assert_equal [false, true, false], lazy.to_ca.to_a
  end

  def test_lazy_gt_returns_cabincmp
    setup_pair
    lazy = @a.lazy.gt(@b)
    assert_kind_of CABinCmp, lazy
    assert_equal @a.gt(@b).to_a, lazy.to_ca.to_a
  end

  def test_lazy_lt_via_operator
    setup_pair
    lazy = @a.lazy < @b
    assert_kind_of CABinCmp, lazy
    assert_equal (@a < @b).to_a, lazy.to_ca.to_a
  end

  # --- generated-file symbol audit ---------------------------------------

  def test_moncmp_symbols_in_kernels_c
    kernels_c = Dir[File.expand_path('../../../ext/carray_kernels_*.c', __FILE__)].map { |__f| File.read(__f, encoding: 'UTF-8') }.join("\n")
    %w[is_nan is_inf is_finite].each do |op|
      assert_match(/ca_moncmp_#{op}\[CA_NTYPE\]/, kernels_c,
                   "moncmp table #{op} missing")
      assert_match(/VALUE rb_ca_#{op} \(VALUE self\)/, kernels_c,
                   "moncmp wrapper rb_ca_#{op} missing")
    end
  end

  def test_bincmp_symbols_in_kernels_c
    kernels_c = Dir[File.expand_path('../../../ext/carray_kernels_*.c', __FILE__)].map { |__f| File.read(__f, encoding: 'UTF-8') }.join("\n")
    %w[feq eq ne gt lt ge le match is_kind_of].each do |op|
      assert_match(/ca_bincmp_#{op}\[CA_NTYPE\]/, kernels_c,
                   "bincmp table #{op} missing")
      assert_match(/VALUE rb_ca_#{op} \(VALUE self, VALUE other\)/, kernels_c,
                   "bincmp wrapper rb_ca_#{op} missing")
    end
  end

  def test_bincmp_aliases_in_init
    kernels_c = Dir[File.expand_path('../../../ext/carray_kernels_*.c', __FILE__)].map { |__f| File.read(__f, encoding: 'UTF-8') }.join("\n")
    assert_match(/rb_define_alias\(rb_cCArray, ">", "gt"\)/, kernels_c)
    assert_match(/rb_define_alias\(rb_cCArray, "<", "lt"\)/, kernels_c)
    assert_match(/rb_define_alias\(rb_cCArray, ">=", "ge"\)/, kernels_c)
    assert_match(/rb_define_alias\(rb_cCArray, "<=", "le"\)/, kernels_c)
    assert_match(/rb_define_alias\(rb_cCArray, "=~", "match"\)/, kernels_c)
  end
end

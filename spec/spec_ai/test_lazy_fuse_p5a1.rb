# ---------------------------------------------------------------------------
# spec_ai/test_lazy_fuse_p5a1.rb
#
# Phase 5a P.5a.1 — CArray.fuse smoke + polymorphic numeric helper.
#
# Pins:
#  - CArray arg path: .lazy wrap + auto-materialise on block exit
#  - Numeric arg path: pass-through (no .lazy), Numeric in/out preserved
#  - Polymorphic helper idiom (= §1.0 motivation): same expression carries
#    both Float and CArray paths under `using CArray::CoreExtensions`
#  - Shadow readonly enforcement (= rev3 C3, parent §3.4):
#    `fuse(arr) { |a| a[0] = v }` raises
#  - Captured eager array remains mutable (= block-external capture)
#  - Nested fuse: inner exit materialises (= parent §4.5.2 C5)
#  - Bare CArray entity return passes through unchanged
#  - Multi-arg + mixed CArray/Numeric arg combinations
#  - block missing raises LocalJumpError
# ---------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path('../../../ext', __FILE__)
$LOAD_PATH.unshift File.expand_path('../../../lib', __FILE__)

require 'test/unit'
require 'carray'
require 'carray/core_extensions'

class TestLazyFuseP5a1 < Test::Unit::TestCase
  using CArray::CoreExtensions

  def setup
    @arr = CArray.float64(5).seq(20.0, 1.0)
  end

  def magnus(t)
    CArray.fuse(t) { |x| 6.1078 * ((17.27 * x) / (x + 237.3)).exp }
  end

  # --- polymorphic helper -------------------------------------------------

  def test_polymorphic_helper_numeric_path_returns_float
    r = magnus(25.0)
    assert_instance_of Float, r
    assert_in_delta 31.677, r, 0.001
  end

  def test_polymorphic_helper_carray_path_returns_carray
    r = magnus(@arr)
    assert_kind_of CArray, r
    refute_kind_of CAMonOp, r
    refute_kind_of CABinOp, r
    # First element corresponds to t=20.0
    expected = 6.1078 * Math.exp(17.27 * 20.0 / (20.0 + 237.3))
    assert_in_delta expected, r[0], 1e-9
  end

  def test_polymorphic_helper_byte_parity_against_eager
    eager = 6.1078 * ((17.27 * @arr) / (@arr + 237.3)).exp
    lazy_via_fuse = magnus(@arr)
    @arr.elements.times do |i|
      assert_in_delta eager[i], lazy_via_fuse[i], 1e-12,
                      "byte parity at index #{i}"
    end
  end

  # --- argument handling --------------------------------------------------

  def test_carray_arg_is_lazy_wrapped_in_block
    seen_class = nil
    CArray.fuse(@arr) { |shadow| seen_class = shadow.class; shadow }
    assert_equal CALazyMarker, seen_class
  end

  def test_numeric_arg_passes_through_unchanged
    seen = nil
    CArray.fuse(3.14) { |x| seen = x; x }
    assert_equal 3.14, seen
    assert_instance_of Float, seen
  end

  def test_integer_arg_passes_through
    r = CArray.fuse(5) { |x| x + 1 }
    assert_equal 6, r
    assert_instance_of Integer, r
  end

  def test_mixed_args
    b = CArray.float64(5).seq(1.0, 1.0)
    r = CArray.fuse(@arr, b) { |a, c| a * 2 + c }
    assert_kind_of CArray, r
    assert_equal [41.0, 44.0, 47.0, 50.0, 53.0], r.to_a
  end

  def test_carray_plus_numeric_args
    r = CArray.fuse(@arr, 10.0) { |a, x| a + x }
    assert_kind_of CArray, r
    assert_equal [30.0, 31.0, 32.0, 33.0, 34.0], r.to_a
  end

  # --- return value handling ----------------------------------------------

  def test_bare_lazy_view_auto_materialises
    r = CArray.fuse(@arr) { |a| a + 1 }
    assert_kind_of CArray, r
    refute_kind_of CAMonOp, r
    refute_kind_of CABinOp, r
  end

  def test_bare_carray_entity_passes_through
    plain = CArray.float64(3).seq(0)
    r = CArray.fuse(@arr) { plain }
    assert_same plain, r
  end

  def test_nil_return_passes_through
    r = CArray.fuse(@arr) { nil }
    assert_nil r
  end

  # --- shadow readonly (rev3 C3) ------------------------------------------

  def test_shadow_destructive_op_raises
    assert_raise(RuntimeError) do
      CArray.fuse(@arr) { |shadow| shadow[0] = 99.0 }
    end
  end

  def test_captured_eager_array_still_mutable
    captured = CArray.float64(3).seq(0)
    CArray.fuse(@arr) { |_a| captured[0] = 99.0; nil }
    assert_equal 99.0, captured[0]
  end

  def test_shadow_does_not_mutate_original
    original_first = @arr[0]
    begin
      CArray.fuse(@arr) { |shadow| shadow[0] = -1.0 }
    rescue RuntimeError
      # expected
    end
    assert_equal original_first, @arr[0]
  end

  # --- nested fuse (parent §4.5.2 C5) -------------------------------------

  def test_nested_fuse_inner_exit_materialises
    inner_class = nil
    CArray.fuse(@arr) do |a|
      inner = CArray.fuse(a) { |a2| a2 + 1 }
      inner_class = inner.class
      a
    end
    # inner_class should be a materialised CArray, not a lazy node
    assert_kind_of Class, inner_class
    refute_equal CAMonOp, inner_class
    refute_equal CABinOp, inner_class
  end

  # --- block missing ------------------------------------------------------

  def test_no_block_raises
    assert_raise(LocalJumpError) { CArray.fuse(@arr) }
  end

  # --- regression: .lazy marker is readonly (Phase 1 spec compliance) ------

  def test_lazy_marker_is_readonly
    m = @arr.lazy
    assert_raise(RuntimeError) { m[0] = 99.0 }
  end
end

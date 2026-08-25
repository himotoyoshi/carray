# API harmonisation A.1: rb_ca_parse_reduce_axes_kw test pin.
#
# Validates that the kwarg-form parser is byte-parity with the variadic
# parser across {Qnil omit / Integer / Array} forms + range / duplicate /
# overflow / type errors.  Establishes the contract that the upcoming
# mkkernel emit refactor will rely on.

require "test/unit"
require "carray"

# === CARRAY_DEV_BUILD guard (auto-added by S.7) ===
# This test exercises smoke surface gated by -DCARRAY_DEV_BUILD.
# Rebuild with `CARRAY_DEV=1 rake build_ext` to enable.
unless CArray.respond_to?(:t1_smoke)
  warn "skipping #{File.basename(__FILE__)}: requires CARRAY_DEV_BUILD"
  return
end

class TestParseReduceAxesKw < Test::Unit::TestCase

  def setup
    @a3 = CArray.float64(2, 3, 4).seq
    @a1 = CArray.float64(5).seq
  end

  # -- omit / nil => full reduction (D-5 representative pin) -----------

  def test_omit_means_full_reduction
    assert_equal [0, 1, 2], CArray.test_parse_reduce_axes_kw(@a3)
  end

  def test_axis_nil_means_full_reduction
    assert_equal [0, 1, 2], CArray.test_parse_reduce_axes_kw(@a3, axis: nil)
  end

  def test_omit_1d
    assert_equal [0], CArray.test_parse_reduce_axes_kw(@a1)
  end

  # -- Integer form ---------------------------------------------------

  def test_integer_single_axis
    assert_equal [0], CArray.test_parse_reduce_axes_kw(@a3, axis: 0)
    assert_equal [1], CArray.test_parse_reduce_axes_kw(@a3, axis: 1)
    assert_equal [2], CArray.test_parse_reduce_axes_kw(@a3, axis: 2)
  end

  def test_integer_negative_normalised
    assert_equal [2], CArray.test_parse_reduce_axes_kw(@a3, axis: -1)
    assert_equal [1], CArray.test_parse_reduce_axes_kw(@a3, axis: -2)
    assert_equal [0], CArray.test_parse_reduce_axes_kw(@a3, axis: -3)
  end

  # -- Array form -----------------------------------------------------

  def test_array_multi_axes
    assert_equal [0, 2], CArray.test_parse_reduce_axes_kw(@a3, axis: [0, 2])
    assert_equal [1, 2], CArray.test_parse_reduce_axes_kw(@a3, axis: [1, 2])
  end

  def test_array_preserves_input_order
    # Not pre-sorted; matches legacy variadic contract (canonicalise in init_l2).
    assert_equal [2, 0], CArray.test_parse_reduce_axes_kw(@a3, axis: [2, 0])
    assert_equal [1, 0, 2], CArray.test_parse_reduce_axes_kw(@a3, axis: [1, 0, 2])
  end

  def test_array_with_negative
    assert_equal [0, 2], CArray.test_parse_reduce_axes_kw(@a3, axis: [0, -1])
    assert_equal [2, 0], CArray.test_parse_reduce_axes_kw(@a3, axis: [-1, -3])
  end

  def test_array_all_axes
    assert_equal [0, 1, 2], CArray.test_parse_reduce_axes_kw(@a3, axis: [0, 1, 2])
  end

  # -- Error cases ----------------------------------------------------

  def test_axis_out_of_range_positive
    assert_raise(IndexError) do
      CArray.test_parse_reduce_axes_kw(@a3, axis: 3)
    end
  end

  def test_axis_out_of_range_negative
    assert_raise(IndexError) do
      CArray.test_parse_reduce_axes_kw(@a3, axis: -4)
    end
  end

  def test_array_axis_out_of_range
    assert_raise(IndexError) do
      CArray.test_parse_reduce_axes_kw(@a3, axis: [0, 5])
    end
  end

  def test_duplicate_axes
    assert_raise(ArgumentError) do
      CArray.test_parse_reduce_axes_kw(@a3, axis: [0, 0])
    end
  end

  def test_duplicate_via_negative_normalisation
    # axis: [0, -3] both normalise to 0 → duplicate
    assert_raise(ArgumentError) do
      CArray.test_parse_reduce_axes_kw(@a3, axis: [0, -3])
    end
  end

  def test_empty_array
    assert_raise(ArgumentError) do
      CArray.test_parse_reduce_axes_kw(@a3, axis: [])
    end
  end

  def test_too_many_axes
    assert_raise(ArgumentError) do
      CArray.test_parse_reduce_axes_kw(@a3, axis: [0, 1, 2, 0])  # > ndim
    end
  end

  # -- Type errors (kwarg-specific, not present in variadic) ----------

  def test_range_rejected
    assert_raise(TypeError) do
      CArray.test_parse_reduce_axes_kw(@a3, axis: 0..1)
    end
  end

  def test_string_rejected
    assert_raise(TypeError) do
      CArray.test_parse_reduce_axes_kw(@a3, axis: "0")
    end
  end

  def test_float_rejected
    # Float is not Integer; rb_obj_is_kind_of(rb_cInteger) check.
    assert_raise(TypeError) do
      CArray.test_parse_reduce_axes_kw(@a3, axis: 0.5)
    end
  end

  def test_nil_in_array_raises
    # Array elements go through NUM2SIZE which raises TypeError on nil.
    assert_raise(TypeError) do
      CArray.test_parse_reduce_axes_kw(@a3, axis: [0, nil])
    end
  end

  # -- Parity with variadic entry -------------------------------------
  # The kwarg entry must produce byte-identical out_axes[] to the
  # variadic entry for every form that both accept.

  def test_parity_omit_vs_argc0
    kw = CArray.test_parse_reduce_axes_kw(@a3)
    va = CArray.t1_test_parse_reduce_axes(@a3)
    assert_equal va, kw
  end

  def test_parity_single_axis
    [0, 1, 2, -1, -2, -3].each do |ax|
      kw = CArray.test_parse_reduce_axes_kw(@a3, axis: ax)
      va = CArray.t1_test_parse_reduce_axes(@a3, ax)
      assert_equal va, kw, "axis: #{ax}"
    end
  end

  def test_parity_array_form
    [[0, 1], [0, 2], [1, 2], [2, 0], [1, 0, 2], [-1, -2]].each do |ax|
      kw = CArray.test_parse_reduce_axes_kw(@a3, axis: ax)
      va = CArray.t1_test_parse_reduce_axes(@a3, ax)  # single-Array argv form
      assert_equal va, kw, "axis: #{ax.inspect}"
    end
  end

end

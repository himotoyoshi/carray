# spec_ai/test_sweep_engine_shape.rb
#
# The sweep bridge (ca_call_cfunc_* / ca_call_cslab_*) pairs operands by
# shape: a scalar pairs with anything, two arrays only when their shapes
# agree.  Pinned through both the raw layer, where the caller allocates the
# output and nothing checks the shapes before the engine does, and the typed
# layer (CAMath functions), which templates the output from the inputs.

require "test/unit"
require "carray"

ext_dir = File.expand_path("ext_sweep_raw", __dir__)
$LOAD_PATH.unshift(ext_dir) unless $LOAD_PATH.include?(ext_dir)
begin
  require "sweep_raw"
rescue LoadError
  warn "[skip] test_sweep_engine_shape.rb: sweep_raw fixture not built " \
       "(run `rake build_author_surface_smoke`)"
  return
end

class TestSweepEngineShape < Test::Unit::TestCase

  RAW = [:__sweep_raw_add__, :__sweep_raw_add_slab__]

  def f64 (*shape)
    CArray.float64(*shape) { |*i| i.sum + 1.0 }
  end

  # A one-cell array is an array, not a scalar: it does not pair with an
  # array of another size.  (The output here is one cell, so accepting the
  # pair would write past it.)
  def test_raw_one_cell_array_does_not_pair_with_larger
    RAW.each do |m|
      out = CArray.float64(1)
      assert_raise(ArgumentError, m.to_s) { CArray.send(m, out, f64(1), f64(2)) }
    end
  end

  def test_raw_one_cell_array_first_then_larger_input
    RAW.each do |m|
      out = CArray.float64(3)
      assert_raise(ArgumentError, m.to_s) { CArray.send(m, out, f64(1), f64(3)) }
    end
  end

  # Same number of cells, different shape.
  def test_raw_same_size_different_shape
    RAW.each do |m|
      out = CArray.float64(2, 3)
      assert_raise(ArgumentError, m.to_s) { CArray.send(m, out, f64(2, 3), f64(3, 2)) }
    end
  end

  def test_raw_same_size_different_ndim
    RAW.each do |m|
      out = CArray.float64(6)
      assert_raise(ArgumentError, m.to_s) { CArray.send(m, out, f64(6), f64(2, 3)) }
    end
  end

  def test_raw_message_names_both_shapes
    e = assert_raise(ArgumentError) {
      CArray.__sweep_raw_add__(CArray.float64(2, 3), f64(2, 3), f64(3, 2))
    }
    assert_match(/\[2, 3\]/, e.message)
    assert_match(/\[3, 2\]/, e.message)
  end

  def test_raw_same_shape
    RAW.each do |m|
      out = CArray.float64(2, 3)
      CArray.send(m, out, f64(2, 3), f64(2, 3))
      assert_equal (f64(2, 3) * 2).to_a, out.to_a, m.to_s
    end
  end

  def test_raw_scalar_pairs_with_array
    RAW.each do |m|
      out = CArray.float64(2, 3)
      CArray.send(m, out, f64(2, 3), CScalar.float64 { 10.0 })
      assert_equal (f64(2, 3) + 10).to_a, out.to_a, m.to_s
    end
  end

  def test_raw_all_scalar
    RAW.each do |m|
      out = CScalar.float64
      CArray.send(m, out, CScalar.float64 { 1.5 }, CScalar.float64 { 2.0 })
      assert_equal 3.5, out[0], m.to_s
    end
  end

  # Typed layer: the output is templated from the inputs.
  def test_typed_same_size_different_shape
    assert_raise(ArgumentError) {
      CAMath.spherical_to_xyz(f64(2, 3), f64(3, 2), f64(3, 2))
    }
  end

  def test_typed_one_cell_array_does_not_pair_with_larger
    assert_raise(ArgumentError) { CAMath.spherical_to_xyz(f64(1), f64(5), f64(5)) }
  end

  def test_typed_same_shape
    r = CAMath.spherical_to_xyz(f64(2, 3), f64(2, 3), f64(2, 3))
    assert_equal [[2, 3]] * 3, r.map(&:shape)
  end

  def test_typed_scalar_pairs_with_array
    r = CAMath.spherical_to_xyz(1.0, f64(2, 3), 0.5)
    assert_equal [[2, 3]] * 3, r.map(&:shape)
  end
end

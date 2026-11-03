# spec_ai/test_sweep_engine_output.rb
#
# What the sweep bridge does to its outputs, through the raw layer where the
# caller allocates them.  Both paths.

require "test/unit"
require "carray"

ext_dir = File.expand_path("ext_sweep_raw", __dir__)
$LOAD_PATH.unshift(ext_dir) unless $LOAD_PATH.include?(ext_dir)
begin
  require "sweep_raw"
rescue LoadError
  warn "[skip] test_sweep_engine_output.rb: sweep_raw fixture not built " \
       "(run `rake build_author_surface_smoke`)"
  return
end

class TestSweepEngineOutput < Test::Unit::TestCase

  RAW = [:__sweep_raw_add__, :__sweep_raw_add_slab__]

  def f64 (n)
    CArray.float64(n) { |i| i + 1.0 }
  end

  def scalar (v = 0.0)
    CScalar.float64.tap { |s| s[0] = v }
  end

  # One cell of output cannot take a walk over many; with a masked input
  # this used to write the whole mask over a one-byte buffer.
  def test_scalar_output_beside_an_array_is_refused
    RAW.each do |m|
      a = f64(4)
      a[1] = UNDEF
      assert_raise(ArgumentError, m.to_s) { CArray.send(m, scalar, a, a) }
      assert_raise(ArgumentError, m.to_s) { CArray.send(m, scalar, f64(4), scalar) }
      assert_raise(ArgumentError, m.to_s) { CArray.send(m, scalar, f64(1), scalar) }
    end
  end

  def test_scalar_output_with_scalar_inputs
    RAW.each do |m|
      out = scalar
      CArray.send(m, out, scalar(2.0), scalar(3.0))
      assert_equal 5.0, out[0], m.to_s
    end
  end

  # The output's mask after the walk is the OR of the input masks, whatever
  # it was before.
  def test_output_mask_is_overwritten_when_an_input_is_masked
    RAW.each do |m|
      a = f64(3)
      a[1] = UNDEF
      out = f64(3)
      out[0] = UNDEF
      CArray.send(m, out, a, a)
      assert_equal [false, true, false], out.is_masked.to_a, m.to_s
    end
  end

  def test_output_mask_is_overwritten_when_no_input_is_masked
    RAW.each do |m|
      out = f64(3)
      out[0] = UNDEF
      CArray.send(m, out, f64(3), f64(3))
      assert_equal [2.0, 4.0, 6.0], out.to_a, m.to_s
    end
  end

  def test_output_view_of_a_masked_array
    RAW.each do |m|
      { block: ->(x) { x[1..3] },
        flip:  ->(x) { x.flip(0) },
        grid:  ->(x) { x[CA_INT32([3, 1, 0, 2])] } }.each do |name, view|
        base = f64(4)
        base[] = -1.0
        base[0..1] = UNDEF
        out = view.(base)
        CArray.send(m, out, CArray.float64(*out.shape) { 1.0 }, CScalar.float64.tap { |s| s[0] = 0.0 })
        assert_equal Array.new(out.elements, 1.0), out.to_a, "#{m} #{name}"
      end
    end
  end

  def test_fsync_takes_only_zero_and_one
    [:__sweep_raw_add_fsync__, :__sweep_raw_add_slab_fsync__].each do |m|
      ["ab0", "120", "1x0"].each do |fsync|
        out = f64(3)
        e = assert_raise(RuntimeError, "#{m} #{fsync}") {
          CArray.send(m, fsync, out, f64(3), f64(3))
        }
        assert_match(/invalid character/, e.message)
        assert_equal [1.0, 2.0, 3.0], out.to_a
      end
      out = f64(3)
      CArray.send(m, "100", out, f64(3), f64(3))
      assert_equal [2.0, 4.0, 6.0], out.to_a
    end
  end

  def test_output_without_a_mask_does_not_get_one
    RAW.each do |m|
      out = f64(3)
      CArray.send(m, out, f64(3), f64(3))
      assert_false out.has_mask?, m.to_s
    end
  end
end

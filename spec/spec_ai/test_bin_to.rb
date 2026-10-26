# Test for CArray#bin_to (bin values against explicit, possibly
# non-uniform edges).  Sibling of `bin` (uniform) and `snap_to` (value).

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../ext", __dir__)
require "test/unit"
require "carray"

class TestBinTo < Test::Unit::TestCase

  def setup
    @e = CA_FLOAT64([0, 1, 10, 100])     # 3 non-uniform bins: [0,1) [1,10) [10,100)
  end

  def test_non_uniform_in_range
    v = CA_FLOAT64([0.5, 5.0, 50.0, 1.0, 10.0])
    assert_equal [0, 1, 2, 1, 2], v.bin_to(@e).to_a
  end

  def test_out_of_range_masked_by_default
    v = CA_FLOAT64([0.5, -1.0, 200.0])
    b = v.bin_to(@e)
    assert_equal [false, true, true], b.is_masked.to_a
    assert_equal 0, b[0]
  end

  def test_lfill_ufill_clamp
    v = CA_FLOAT64([0.5, -1.0, 200.0])
    assert_equal [0, 0, 2], v.bin_to(@e, lfill: 0, ufill: 2).to_a
  end

  def test_lfill_only_masks_upper
    v = CA_FLOAT64([0.5, -1.0, 200.0])
    b = v.bin_to(@e, lfill: -1)
    assert_equal(-1, b[1])              # below -> lfill
    assert_equal true, b.is_masked[2]      # above -> mask
  end

  def test_include_max
    assert_equal [2], CA_FLOAT64([100.0]).bin_to(@e, include_max: true).to_a
    assert_equal true, CA_FLOAT64([100.0]).bin_to(@e).is_masked[0]
  end

  def test_nan_and_mask_propagate
    v = CA_FLOAT64([0.5, Float::NAN, 5.0]).to_ca
    v[2] = UNDEF
    b = v.bin_to(@e)
    assert_equal [false, true, true], b.is_masked.to_a
    assert_equal 0, b[0]
  end

  def test_integer_input_coerced
    assert_equal [0, 1, 2], CA_INT32([0, 5, 50]).bin_to(@e).to_a
  end

  def test_dtype_and_shape_preserved
    v = CArray.float64(2, 3) { |i, j| (i * 3 + j) * 0.7 }
    b = v.bin_to(@e)
    assert_equal CA_INT64, b.data_type
    assert_equal [2, 3], b.shape
  end

  def test_uniform_edges_like_a_histogram_axis
    e = CArray.float64(6).span(0..5)   # 5 uniform bins
    v = CA_FLOAT64([0.5, 1.5, 4.9, 5.0])
    assert_equal [0, 1, 4], v.bin_to(e).to_a[0, 3]
    assert_equal true, v.bin_to(e).is_masked[3]   # 5.0 == top edge -> over
  end

  # Edges that pass for equally spaced but sit slightly off the straight
  # line: a value just on one side of a stored edge goes to the bin that
  # edge bounds, as the binary search over the edges would put it.
  def test_nearly_uniform_edges_bin_by_the_stored_edges
    [[1e-6, 5e-13], [1e-6, -5e-13], [1e-4, 8e-13]].each do |dx, d|
      e = (0..10).map { |k| k * dx }
      e[5] += d
      vals = [e[5] - d.abs * 0.4, e[5].prev_float, e[5], e[5].next_float,
              e[5] + d.abs * 0.4]
      exp = vals.map { |v| e.rindex { |x| x <= v } }
      edges = CArray.float64(e.size) { |i| e[i] }
      x = CArray.float64(vals.size) { |i| vals[i] }
      assert_equal exp, x.bin_to(edges).to_a, "dx=#{dx} d=#{d}"
      counts = Array.new(10, 0)
      exp.each { |k| counts[k] += 1 }
      assert_equal counts, x.histogram1d(edges: edges).counts.to_a, "dx=#{dx} d=#{d}"
    end
  end

  def test_edges_validation
    assert_raise(ArgumentError) { CA_FLOAT64([1.0]).bin_to(CA_FLOAT64([0.0])) }       # < 2 edges
    assert_raise(ArgumentError) { CA_FLOAT64([1.0]).bin_to(CArray.float64(2, 2)) }    # not 1-D
  end

end

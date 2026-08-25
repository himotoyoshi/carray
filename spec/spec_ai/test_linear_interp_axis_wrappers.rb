require "test/unit"
require "carray"

# PROPOSAL_LINEAR_INTERP_AXIS L.2.5 — Ruby surface wrappers for
# linear_section / linear_fetch (lib/carray/ordering.rb).
class TestLinearInterpAxisWrappers < Test::Unit::TestCase

  def test_linear_section_default_method_is_binary
    y = CA_DOUBLE([0.0, 1.0, 3.0, 6.0, 10.0])
    assert_in_delta y.linear_section(4.0, method: :binary),
                    y.linear_section(4.0), 1e-12
  end

  def test_linear_section_method_keyword
    y = CA_DOUBLE([0.0, 1.0, 3.0, 6.0, 10.0])
    # Both should produce the same answer for a value strictly inside range.
    a = y.linear_section(4.0, method: :binary)
    b = y.linear_section(4.0, method: :linear)
    assert_in_delta a, b, 1e-12
  end

  def test_linear_section_unknown_method_raises
    y = CA_DOUBLE([0.0, 1.0, 2.0])
    assert_raise(ArgumentError) do
      y.linear_section(1.0, method: :bogus)
    end
  end

  def test_linear_section_int_self_auto_cast
    yi = CA_INT64([0, 1, 2, 3, 4])
    assert_in_delta 2.5, yi.linear_section(2.5), 1e-12
  end

  def test_linear_section_2d_flat_default
    m = CArray.float64(3, 4) { |i, j| (i * 4 + j).to_f }   # flattens to 0..11
    assert_in_delta 5.5, m.linear_section(5.5), 1e-12
  end

  def test_linear_section_2d_axis
    m = CArray.float64(3, 4) { |i, j| (i * 100 + j).to_f }
    out = m.linear_section(1.5, axis: 1)
    assert_equal [3], out.dim
    # Row 0 [0,1,2,3] -> 1.5; rows 1,2 ([100..],[200..]) query 1.5 out of
    # range -> NaN (Option C: no extrapolation).
    assert_in_delta 1.5, out[0], 1e-12
    assert out[1].nan?, "out-of-range query should be NaN"
  end

  def test_linear_section_axis_negative
    m = CArray.float64(3, 5) { |i, j| (i * 100 + j).to_f }
    out_pos = m.linear_section(2.5, axis: 1)
    out_neg = m.linear_section(2.5, axis: -1)
    # Rows 1,2 are out of range for 2.5 -> NaN; compare NaN-robustly
    # (NaN != NaN would break a plain array equality).
    assert_equal out_pos.to_a.map(&:to_s), out_neg.to_a.map(&:to_s)
  end

  def test_linear_section_axis_out_of_range
    m = CArray.float64(3, 5) { |i, j| (i * 100 + j).to_f }
    assert_raise(ArgumentError) { m.linear_section(1.0, axis: 5) }
  end

  def test_linear_fetch_scalar
    y = CA_DOUBLE([0.0, 2.0, 4.0, 6.0, 8.0])
    assert_in_delta 5.0, y.linear_fetch(2.5), 1e-12
  end

  def test_linear_fetch_oob_returns_nil
    y = CA_DOUBLE([0.0, 1.0, 2.0])
    assert_nil y.linear_fetch(-0.5)
    assert_nil y.linear_fetch(99.0)
  end

  def test_linear_fetch_2d_axis
    m = CArray.float64(3, 4) { |i, j| (i * 10 + j).to_f }
    out = m.linear_fetch(1.5, axis: 1)
    assert_equal [3], out.dim
    assert_in_delta 1.5,  out[0], 1e-12
    assert_in_delta 11.5, out[1], 1e-12
    assert_in_delta 21.5, out[2], 1e-12
  end

  def test_linear_fetch_2d_flat_default
    m = CArray.float64(2, 3) { |i, j| (i * 3 + j).to_f }   # 0..5 row-major
    assert_in_delta 1.5, m.linear_fetch(1.5), 1e-12
  end

  # ----------------------------------------------------------------
  # Descending grids: :binary used to mishandle interior values
  # because its boundary guard and bisection were ascending-only.
  # It must now agree with :linear (the direction-safe reference)
  # and with the true fractional index.
  # ----------------------------------------------------------------

  def test_linear_section_descending_interior_binary
    d = CA_DOUBLE([10.0, 6.0, 3.0, 1.0, 0.0])
    # 4.0 brackets d[1]=6, d[2]=3 -> 1 + (4-6)/(3-6) = 1.6666...
    assert_in_delta 1.6666666666666665, d.linear_section(4.0, method: :binary), 1e-12
    # 0.5 brackets d[3]=1, d[4]=0 -> 3 + (0.5-1)/(0-1) = 3.5
    assert_in_delta 3.5, d.linear_section(0.5, method: :binary), 1e-12
  end

  def test_linear_section_descending_binary_matches_linear
    d = CA_DOUBLE([10.0, 6.0, 3.0, 1.0, 0.0])
    [9.5, 7.0, 4.0, 2.0, 1.0, 0.5].each do |v|
      assert_in_delta d.linear_section(v, method: :linear),
                      d.linear_section(v, method: :binary), 1e-12,
                      "binary should equal linear for descending value #{v}"
    end
  end

  def test_linear_section_descending_exact_endpoints
    d = CA_DOUBLE([10.0, 6.0, 3.0, 1.0, 0.0])
    assert_in_delta 0.0, d.linear_section(10.0, method: :binary), 1e-12
    assert_in_delta 4.0, d.linear_section(0.0,  method: :binary), 1e-12
    assert_in_delta 2.0, d.linear_section(3.0,  method: :binary), 1e-12
  end

  def test_self_mask_raises
    y = CA_DOUBLE([0.0, 1.0, 2.0])
    y[1] = UNDEF
    assert_raise(RuntimeError) { y.linear_section(1.0) }
    assert_raise(RuntimeError) { y.linear_fetch(1.0) }
  end

end

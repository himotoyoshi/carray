require "test/unit"
require "carray"

# PROPOSAL_LINEAR_INTERP_AXIS L.1+L.2 — kernel-level tests for
# linear_section_binary_ki / linear_section_linear_ki / linear_fetch_ki.
# These exercise the mkkernel `search` form with output: :f64 + NaN
# sentinel (= no_match_check: "isnan(op[0])" hook added in L.1).
class TestLinearInterpAxisKernels < Test::Unit::TestCase

  # ---- linear_section_binary (= legacy `section` semantic) -------------

  def test_binary_scalar_exact
    y = CArray.float64(10) { |i| i.to_f }
    assert_in_delta 2.5, y.linear_section_binary_ki(2.5, 0), 1e-12
    assert_in_delta 0.0, y.linear_section_binary_ki(0.0, 0), 1e-12
    assert_in_delta 9.0, y.linear_section_binary_ki(9.0, 0), 1e-12
  end

  def test_binary_scalar_out_of_range_returns_nil
    # Option C: linear_section no longer extrapolates.  A query outside the
    # grid (codomain [0, n-1]) is "no answer" -> nil scalar (NaN in array
    # form), matching :linear and linear_fetch.
    y = CArray.float64(10) { |i| i.to_f }
    assert_nil y.linear_section_binary_ki(-5.0, 0)
    assert_nil y.linear_section_binary_ki(99.0, 0)
  end

  def test_binary_carray_val_returns_array
    y = CArray.float64(10) { |i| i.to_f }
    vals = CA_DOUBLE([1.5, 3.5, 7.5])
    out = y.linear_section_binary_ki(vals, 0)
    assert_instance_of CArray, out
    assert_equal CA_FLOAT64, out.data_type
    assert_equal [3], out.dim
    [1.5, 3.5, 7.5].each_with_index do |v, i|
      assert_in_delta v, out[i], 1e-12
    end
  end

  def test_binary_mask_self_raises
    y = CArray.float64(10) { |i| i.to_f }
    y[3] = UNDEF
    assert_raise(RuntimeError) { y.linear_section_binary_ki(2.5, 0) }
  end

  # ---- linear_section_linear (= legacy `section_linear` semantic) ------

  def test_linear_scalar_in_range
    y = CA_DOUBLE([0.0, 1.0, 3.0, 6.0, 10.0])
    # Find 4.0: lies between y[2]=3 and y[3]=6, fractional = 2 + 1/3
    assert_in_delta 2 + 1.0/3.0, y.linear_section_linear_ki(4.0, 0), 1e-12
  end

  def test_linear_no_match_returns_nan_scalar
    # Linear scan returns nil (= NaN sentinel) when no bracketing pair.
    y = CA_DOUBLE([0.0, 1.0, 2.0])
    assert_nil y.linear_section_linear_ki(99.0, 0)
  end

  def test_linear_no_match_array_writes_nan
    y = CA_DOUBLE([0.0, 1.0, 2.0])
    vals = CA_DOUBLE([0.5, 99.0])
    out = y.linear_section_linear_ki(vals, 0)
    assert_in_delta 0.5, out[0], 1e-12
    assert out[1].nan?, "expected NaN sentinel, got #{out[1]}"
  end

  # ---- linear_fetch (= legacy `fetch_linear_addr` semantic) ------------

  def test_fetch_scalar_in_range
    y = CArray.float64(10) { |i| (i * 2.0) }   # 0,2,4,...,18
    assert_in_delta 5.0, y.linear_fetch_ki(2.5, 0), 1e-12   # halfway between 4 and 6
  end

  def test_fetch_endpoints
    y = CArray.float64(5) { |i| i.to_f }
    assert_in_delta 0.0, y.linear_fetch_ki(0.0, 0), 1e-12
    assert_in_delta 4.0, y.linear_fetch_ki(4.0, 0), 1e-12
  end

  def test_fetch_oob_returns_nil_scalar
    y = CArray.float64(5) { |i| i.to_f }
    assert_nil y.linear_fetch_ki(-0.1, 0)
    assert_nil y.linear_fetch_ki(4.1, 0)
  end

  def test_fetch_carray_addr_returns_array
    y = CArray.float64(10) { |i| (i * 2.0) }
    addrs = CA_DOUBLE([0.0, 1.5, 9.0, 99.0])
    out   = y.linear_fetch_ki(addrs, 0)
    assert_in_delta 0.0,  out[0], 1e-12
    assert_in_delta 3.0,  out[1], 1e-12   # 1.5 * 2.0
    assert_in_delta 18.0, out[2], 1e-12
    assert out[3].nan?, "OOB query should yield NaN in array path"
  end

  # ---- 2-D axis化 (= (β) broadcast case) -------------------------------

  def test_fetch_2d_axis1
    m = CArray.float64(3, 4) { |i, j| (i * 10 + j).to_f }
    # Per-row fetch at addr 1.5 -> [0.5, 10.5, 20.5] + 1 = [1.5, 11.5, 21.5]
    out = m.linear_fetch_ki(1.5, 1)
    assert_equal [3], out.dim
    assert_in_delta 1.5,  out[0], 1e-12
    assert_in_delta 11.5, out[1], 1e-12
    assert_in_delta 21.5, out[2], 1e-12
  end

  def test_section_2d_axis1_per_row_via_reshape
    # rev5: self [3, 5] axis 1, per-row scalar query は val.reshape(3, 1)
    # で A3 with M=1 に誘導、result [3, 1]
    m = CArray.float64(3, 5) { |i, j| (i * 100 + j).to_f }
    vals_pf = CArray.float64(3, 1)
    vals_pf[0, 0] = 2.5; vals_pf[1, 0] = 102.5; vals_pf[2, 0] = 202.5
    out  = m.linear_section_binary_ki(vals_pf, 1)
    assert_equal [3, 1], out.dim
    [2.5, 2.5, 2.5].each_with_index do |v, i|
      assert_in_delta v, out[i, 0], 1e-12
    end
  end

  def test_section_2d_axis1_1d_val_shared
    # rev5: self [3, 5] axis 1, val 1-D [3] -> A2 shared M=3, result [3, 3]
    m = CArray.float64(3, 5) { |i, j| (i * 100 + j).to_f }
    vals = CA_DOUBLE([2.5, 102.5, 202.5])
    out  = m.linear_section_binary_ki(vals, 1)
    assert_equal [3, 3], out.dim
  end

  def test_section_2d_axis1_query_axis_appended
    # self.shape = (3, 5), N=2 queries broadcast -> (3, 2)
    m = CArray.float64(3, 5) { |i, j| (i * 100 + j).to_f }
    vals = CA_DOUBLE([1.5, 3.5])  # N=2 queries shared across rows
    out  = m.linear_section_binary_ki(vals, 1)
    # base_shape = (3,), val.shape = (2,); not broadcastable -> case B
    # => out.shape = (3, 2).  Each row finds 1.5 and 3.5 in [i*100..i*100+4].
    # row 0: [0..4], finds 1.5 and 3.5 -> [1.5, 3.5]
    # row 1: [100..104], queries 1.5 / 3.5 are out of range -> NaN
    #        (Option C: no extrapolation).  Pin row 0; row 1 is NaN.
    assert_equal [3, 2], out.dim
    assert out[1, 0].nan?, "row 1 out-of-range query should be NaN"
    assert_in_delta 1.5, out[0, 0], 1e-12
    assert_in_delta 3.5, out[0, 1], 1e-12
  end

  # ---- masked query -> masked result (mask_query: :undef) --------------
  #
  # A masked query cell is undetermined, so the answer is undetermined too.
  # Reading the value that happens to sit under the mask would turn "no
  # answer" into an answer, which is what these pin against.

  def test_section_masked_query_cell_is_undef
    y = CArray.float64(10) { |i| i.to_f }
    vals = CA_DOUBLE([1.5, 3.5, 7.5])
    vals[1] = UNDEF
    [:linear_section_binary_ki, :linear_section_linear_ki].each do |ki|
      out = y.send(ki, vals, 0)
      assert_equal [false, true, false], out.mask.to_a, ki.to_s
      assert_in_delta 1.5, out[0], 1e-12
      assert_in_delta 7.5, out[2], 1e-12
    end
  end

  def test_fetch_masked_index_cell_is_undef
    v = CA_DOUBLE([10.0, 20.0, 30.0, 40.0])
    addr = CA_DOUBLE([0.5, 1.5, 2.5])
    addr[1] = UNDEF
    out = v.linear_fetch_ki(addr, 0)
    assert_equal [false, true, false], out.mask.to_a
    assert_in_delta 15.0, out[0], 1e-12
    assert_in_delta 35.0, out[2], 1e-12
  end

  def test_masked_scalar_query_is_nil
    y = CArray.float64(10) { |i| i.to_f }
    assert_nil y.linear_section_binary_ki(UNDEF, 0)
    assert_nil y.linear_section_linear_ki(UNDEF, 0)
    assert_nil y.linear_fetch_ki(UNDEF, 0)
    # A single-element query array collapses to the scalar path, so a masked
    # lone element must reach the same answer.
    lone = CArray.float64(1)
    lone[0] = UNDEF
    assert_nil y.linear_section_binary_ki(lone, 0)
  end

  def test_masked_query_survives_data_type_coercion
    # An integer query is wrapped read-only to float64 before the kernel
    # sees it; the mask must ride along with the wrap.
    y = CArray.float64(10) { |i| i.to_f }
    vals = CA_INT32([1, 3, 7])
    vals[1] = UNDEF
    out = y.linear_section_binary_ki(vals.float64, 0)
    assert_equal [false, true, false], out.mask.to_a
  end

  def test_masked_query_per_axis_forms
    m = CArray.float64(2, 4).seq
    # A2: one shared 1-D query along axis 1
    shared = CA_DOUBLE([0.5, 1.5])
    shared[0] = UNDEF
    out = m.linear_fetch_ki(shared, 1)
    assert_equal [[true, false], [true, false]], out.mask.to_a
    # A3: query matches self.shape with the target axis free
    per_cell = CArray.float64(2, 2) { 1.0 }
    per_cell[0, 1] = UNDEF
    out = m.linear_fetch_ki(per_cell, 1)
    assert_equal [[false, true], [false, false]], out.mask.to_a
  end

  def test_out_of_range_stays_nan_not_masked
    # Only the query's own mask makes an output cell UNDEF.  An in-band
    # out-of-range query keeps the family's NaN sentinel (unchanged).
    y = CArray.float64(10) { |i| i.to_f }
    out = y.linear_section_binary_ki(CA_DOUBLE([1.5, -9.0, 99.0]), 0)
    assert_equal false, out.has_mask?
    assert out[1].nan?
    assert out[2].nan?
  end

end

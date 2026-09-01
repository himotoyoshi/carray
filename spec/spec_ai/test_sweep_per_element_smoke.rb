# spec_ai/test_sweep_per_element_smoke.rb
#
# PROPOSAL_L0_AUTHOR_SURFACE L0.2a — regression pin for the
# CA_FOR_EACH_ELEMENT macro family (READ / MASKED / INOUT /
# INOUT_MASKED / OUT).  Exercises the spec_ai-local fixture at
# ext_per_element_smoke/ (a byte-for-byte mirror of the user-facing
# example examples/c-extensions/per_element/ — the same code an external
# ext author would write to use these macros).

require "test/unit"
require "carray"

ext_dir = File.expand_path("ext_per_element_smoke", __dir__)
$LOAD_PATH.unshift(ext_dir) unless $LOAD_PATH.include?(ext_dir)
begin
  require "per_element"
rescue LoadError
  warn "[skip] test_sweep_per_element_smoke.rb: per_element fixture not built " \
       "(run `rake build_author_surface_smoke`)"
  return
end

class TestSweepPerElementSmoke < Test::Unit::TestCase

  # ---------- (1) READ-only NO_MASK ----------

  def test_sum_contig_entity
    arr = CArray.float64(5){|i| i.to_f + 1.0}
    assert_in_delta 15.0, CArray.demo_sum_f64(arr), 1e-12
  end

  def test_sum_slice_view
    big = CArray.float64(10){|i| i.to_f + 1.0}
    slc = big[2..4]   # [3.0, 4.0, 5.0]
    # AC2 ancestor cascade prevention: view materialises into its own
    # 3-element buffer, not the parent's 10-element buffer.
    assert_in_delta 12.0, CArray.demo_sum_f64(slc), 1e-12
  end

  def test_sum_transpose_view
    mat = CArray.float64(3, 4){|i, j| (i * 4 + j + 1).to_f}
    # transpose is a CAStride view; engine materialises via xfer_all.
    assert_in_delta 78.0, CArray.demo_sum_f64(mat.transpose), 1e-12
  end

  def test_sum_scalar_broadcast
    sc = CScalar.float64
    sc[0] = 3.5
    # scalar: stride collapses to 0, n_kernel = 1.
    assert_in_delta 3.5, CArray.demo_sum_f64(sc), 1e-12
  end

  def test_no_mask_raises_on_masked_input
    arr = CArray.float64(5){|i| i.to_f}
    arr.mask = arr > 2
    assert_raise(RuntimeError) do
      CArray.demo_sum_f64(arr)
    end
  end

  # ---------- (2) READ-only MASKED ----------

  def test_count_unmasked_no_source_mask
    arr = CArray.float64(5){|i| i.to_f}
    assert_equal 5, CArray.demo_count_unmasked_f64(arr)
  end

  def test_count_unmasked_with_mask
    arr = CArray.float64(5){|i| i.to_f}
    arr.mask = arr > 2   # masks i=3,4
    assert_equal 3, CArray.demo_count_unmasked_f64(arr)
  end

  def test_count_unmasked_all_masked
    arr = CArray.float64(5){|i| i.to_f}
    arr.mask = 1
    assert_equal 0, CArray.demo_count_unmasked_f64(arr)
  end

  # ---------- (3) INOUT NO_MASK ----------

  def test_square_contig
    inp = CArray.float64(4){|i| (i + 1).to_f}
    out = CArray.float64(4)
    CArray.demo_square_f64(inp, out)
    assert_equal [1.0, 4.0, 9.0, 16.0], out.to_a
  end

  def test_square_view_to_entity
    big = CArray.float64(10){|i| (i + 1).to_f}
    inp = big[3..5]               # [4.0, 5.0, 6.0]
    out = CArray.float64(3)
    CArray.demo_square_f64(inp, out)
    assert_equal [16.0, 25.0, 36.0], out.to_a
  end

  def test_square_shape_mismatch_raises
    a = CArray.float64(3, 5){|i, j| 1.0}
    b = CArray.float64(4, 5){|i, j| 0.0}
    assert_raise(RuntimeError) do
      CArray.demo_square_f64(a, b)
    end
  end

  def test_square_ndim_mismatch_raises
    a = CArray.float64(6){|i| 1.0}
    b = CArray.float64(2, 3){|i, j| 0.0}
    assert_raise(RuntimeError) do
      CArray.demo_square_f64(a, b)
    end
  end

  # ---------- (4) INOUT MASKED ----------

  def test_safe_sqrt_no_negatives
    inp = CArray.float64(3){|i| (i * i + 1).to_f}   # [1.0, 2.0, 5.0]
    out = CArray.float64(3)
    CArray.demo_safe_sqrt_f64(inp, out)
    assert_in_delta 1.0,             out[0], 1e-12
    assert_in_delta Math.sqrt(2.0),  out[1], 1e-12
    assert_in_delta Math.sqrt(5.0),  out[2], 1e-12
    assert_false out.has_mask?
  end

  def test_safe_sqrt_with_negatives_creates_mask
    inp = CArray.float64(4)
    inp[0] = 4.0; inp[1] = -1.0; inp[2] = 9.0; inp[3] = -3.0
    out = CArray.float64(4)
    CArray.demo_safe_sqrt_f64(inp, out)
    # The macro path doesn't auto-create mask if no INPUT mask; author
    # writes m_out but the engine's m0 is NULL when no input has mask.
    # So the negative cells get out=0 but no mask carry.
    # (This is documented behavior of the masked form when source has
    # no mask: m0 stays NULL so m_out writes are no-ops.)
    assert_equal 2.0, out[0]
    assert_equal 3.0, out[2]
  end

  def test_safe_sqrt_with_input_mask_propagates
    inp = CArray.float64(4){|i| (i + 1).to_f}
    inp.mask = CArray.boolean(4){|i| i == 2}   # mask index 2
    out = CArray.float64(4)
    CArray.demo_safe_sqrt_f64(inp, out)
    # Index 2 is masked: m_out = m_in = 1, out[2] stays masked
    assert_true out.has_mask?
    assert_equal true, out.mask[2]
    assert_equal false, out.mask[0]
    assert_equal false, out.mask[1]
    assert_in_delta Math.sqrt(1.0), out[0], 1e-12
  end

  # ---------- (5) WRITE-only ----------

  def test_iota_offset_step
    out = CArray.float64(5)
    CArray.demo_iota_f64(out, 10.0, 2.0)
    assert_equal [10.0, 12.0, 14.0, 16.0, 18.0], out.to_a
  end

  def test_iota_zero_step
    out = CArray.float64(4)
    CArray.demo_iota_f64(out, 7.5, 0.0)
    assert_equal [7.5, 7.5, 7.5, 7.5], out.to_a
  end

  def test_iota_2d
    out = CArray.float64(2, 3)
    CArray.demo_iota_f64(out, 0.0, 1.0)
    # Flat order: row-major, n_kernel = 6
    assert_equal [[0.0, 1.0, 2.0], [3.0, 4.0, 5.0]], out.to_a
  end

  # ---------- chunking (L0.1) ----------

  def test_chunking_large_array
    # 1M elements: chunk_n_max = 4096 (at f64) → ~245 chunks
    n = 1_000_000
    arr = CArray.float64(n){|i| 1.0}
    assert_in_delta n.to_f, CArray.demo_sum_f64(arr), 1e-6
  end

  def test_chunking_shrinking_view
    # AC2: large parent (10M), small slice (5 elements).  chunked path
    # materialises into a 32KB-ish scratch, never the 80MB parent buffer.
    big = CArray.float64(10_000_000){|i| i.to_f}
    slc = big[1000..1004]
    assert_in_delta 5010.0, CArray.demo_sum_f64(slc), 1e-9
  end

  def test_chunking_transpose_view_non_contig
    # Transpose is non-alias non-contig view; chunked path gathers each
    # chunk via ca_xfer_stride.  Verifies chunk-boundary aware gather.
    mat = CArray.float64(100, 50){|i, j| (i * 50 + j).to_f}
    tr = mat.transpose   # 50x100 = 5000 cells, non-contig
    expected = mat.to_a.flatten.inject(0.0, :+)
    assert_in_delta expected, CArray.demo_sum_f64(tr), 1e-6
  end

  def test_chunking_inout_large
    inp = CArray.float64(10_000){|i| (i + 1).to_f}
    out = CArray.float64(10_000)
    CArray.demo_square_f64(inp, out)
    # spot check
    assert_equal 1.0, out[0]
    assert_equal 4.0, out[1]
    assert_equal (10_000.0 * 10_000.0), out[9999]
  end

  def test_inout_masked_m_out_writes_reach_output
    # Regression: chunked path propagates m0 -> OUTPUT mask at release
    # time so author-written m_out values land in ca_out.mask.
    #
    # Setup: input has mask only at index 0 (= negative source).  Author
    # writes m_out = m_in for all cells (= safe_sqrt's no-extra-mask
    # path).  Expected: OUTPUT mask matches INPUT mask exactly.
    inp = CArray.float64(5){|i| (i + 1).to_f}
    inp.mask = CArray.boolean(5){|i| i == 0 || i == 3}
    out = CArray.float64(5)
    CArray.demo_safe_sqrt_f64(inp, out)
    assert_true out.has_mask?
    assert_equal true, out.mask[0]
    assert_equal false, out.mask[1]
    assert_equal false, out.mask[2]
    assert_equal true, out.mask[3]
    assert_equal false, out.mask[4]
  end
end

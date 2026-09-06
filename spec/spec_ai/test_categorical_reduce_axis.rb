require "carray"
require "test/unit"

# PROPOSAL_CATEGORICAL_REDUCE_AXIS Phase 1 spec.
# Adds `axis:` kwarg to CACategoricalIterator monoid reductions (Phase 1: sum only).
#
# Uses a pure-Ruby fiber-loop reference (CategoricalReduceAxisRef.sum_ref) as the
# byte-parity ground truth. The reference broadcasts codes to h.shape at the Ruby
# level (case A / B / band-only), walks every band-coord fiber, and per-fiber does
# a naive scatter-accumulate. Slow but obviously correct; kernel results MUST match
# it cell-for-cell (byte parity, AC1).

module CategoricalReduceAxisRef
  module_function

  # Generic per-fiber reduce helper. yields the list of contributing h values
  # per (c, band_ix) cell; block returns the reduced value.  Returns a Hash:
  #   {values: <Array of Array of Float>, out_shape: [K, ...band]}
  # Callers use this to derive sum/mean/min/max/count/prod references.
  def per_cell_values(h, cat, axis)
    k        = cat.labels.size
    full_c   = broadcast_codes(cat.codes, h.shape, axis)
    band     = h.shape.dup; band.delete_at(axis)
    hm       = h.has_mask?     ? h.mask     : nil
    cm       = full_c.has_mask? ? full_c.mask : nil
    result   = Hash.new { |h1, k1| h1[k1] = [] }  # (c, band_ix) → [values]
    iter_fiber_coords(band) do |band_ix|
      h.shape[axis].times do |i|
        full_ix = band_ix.dup; full_ix.insert(axis, i)
        next if cm && cm[*full_ix]
        c = full_c[*full_ix]
        next if c < 0 || c >= k
        next if hm && hm[*full_ix]
        result[[c] + band_ix] << h[*full_ix]
      end
    end
    {values: result, k: k, band: band}
  end

  def min_ref(h, cat, axis)
    r    = per_cell_values(h, cat, axis)
    band = r[:band]; k = r[:k]
    out  = CArray.new(h.data_type, [k] + band)
    iter_fiber_coords(band) do |band_ix|
      k.times do |c|
        vs = r[:values][[c] + band_ix]
        if vs.empty? then out[c, *band_ix] = UNDEF
        else               out[c, *band_ix] = vs.min
        end
      end
    end
    out
  end

  def max_ref(h, cat, axis)
    r    = per_cell_values(h, cat, axis)
    band = r[:band]; k = r[:k]
    out  = CArray.new(h.data_type, [k] + band)
    iter_fiber_coords(band) do |band_ix|
      k.times do |c|
        vs = r[:values][[c] + band_ix]
        if vs.empty? then out[c, *band_ix] = UNDEF
        else               out[c, *band_ix] = vs.max
        end
      end
    end
    out
  end

  def mean_ref(h, cat, axis)
    r    = per_cell_values(h, cat, axis)
    band = r[:band]; k = r[:k]
    out  = CArray.float64(*([k] + band))
    iter_fiber_coords(band) do |band_ix|
      k.times do |c|
        vs = r[:values][[c] + band_ix]
        if vs.empty? then out[c, *band_ix] = UNDEF
        else               out[c, *band_ix] = vs.sum(0.0) / vs.size
        end
      end
    end
    out
  end

  def count_ref(h, cat, axis)
    r    = per_cell_values(h, cat, axis)
    band = r[:band]; k = r[:k]
    out  = CArray.int64(*([k] + band)).fill(0)
    iter_fiber_coords(band) do |band_ix|
      k.times { |c| out[c, *band_ix] = r[:values][[c] + band_ix].size }
    end
    out
  end

  # Reference weighted sum / mean per (c, fiber).  Same masking rule as
  # per_cell_values plus weights mask: cell contributes iff h AND weights are
  # both present, in addition to codes valid.  Returns [wsum_arr, wmean_arr]
  # both float64 shape [K, ...band]; wmean masked where sum-of-weights (i.e.
  # cnt = 0) is empty.
  def wsum_wmean_ref(h, cat, weights, axis)
    k       = cat.labels.size
    full_c  = broadcast_codes(cat.codes, h.shape, axis)
    band    = h.shape.dup; band.delete_at(axis)
    hm      = h.has_mask?       ? h.mask       : nil
    wm      = weights.has_mask? ? weights.mask : nil
    cm      = full_c.has_mask?  ? full_c.mask  : nil
    ws_out  = CArray.float64(*([k] + band)).fill(0.0)
    sw_out  = CArray.float64(*([k] + band)).fill(0.0)   # sum of weights
    cnt_out = CArray.int64(*([k] + band)).fill(0)
    iter_fiber_coords(band) do |band_ix|
      h.shape[axis].times do |i|
        full_ix = band_ix.dup; full_ix.insert(axis, i)
        next if cm && cm[*full_ix]
        c = full_c[*full_ix]
        next if c < 0 || c >= k
        next if hm && hm[*full_ix]
        next if wm && wm[*full_ix]
        wv = weights[*full_ix].to_f
        ws_out[c, *band_ix]  = ws_out[c, *band_ix]  + h[*full_ix].to_f * wv
        sw_out[c, *band_ix]  = sw_out[c, *band_ix]  + wv
        cnt_out[c, *band_ix] = cnt_out[c, *band_ix] + 1
      end
    end
    wm_out = CArray.float64(*([k] + band))
    iter_fiber_coords(band) do |band_ix|
      k.times do |c|
        if cnt_out[c, *band_ix] == 0
          wm_out[c, *band_ix] = UNDEF
        else
          wm_out[c, *band_ix] = ws_out[c, *band_ix] / sw_out[c, *band_ix]
        end
      end
    end
    [ws_out, wm_out]
  end

  def prod_ref(h, cat, axis)
    r    = per_cell_values(h, cat, axis)
    band = r[:band]; k = r[:k]
    out  = CArray.float64(*([k] + band)).fill(1.0)
    iter_fiber_coords(band) do |band_ix|
      k.times do |c|
        vs = r[:values][[c] + band_ix]
        out[c, *band_ix] = vs.reduce(1.0) { |acc, v| acc * v }
      end
    end
    out
  end


  # Broadcast codes CArray to `h_shape`, treating `axis` as the reduce direction.
  # Returns a fresh CArray of same dtype as codes, shape == h_shape. Resolves the
  # three supported cases (§2.2 of PROPOSAL rev2):
  #   case A       : codes.ndim == 1 and codes.shape == [h_shape[axis]]
  #   case B       : codes.ndim == h_shape.size and codes.shape == h_shape
  #   band-only    : codes.ndim == h_shape.size - 1 and codes.shape == h_shape without axis
  # Preserves the codes mask under broadcast.
  def broadcast_codes(codes, h_shape, axis)
    ndim = h_shape.size
    out  = CArray.new(codes.data_type, h_shape)
    out.mask = 0 if codes.has_mask?
    case codes.ndim
    when 1
      unless codes.shape == [h_shape[axis]]
        raise ArgumentError, "codes shape #{codes.shape} does not match case A"
      end
      iter_fiber_coords(h_shape) do |full_ix|
        out[*full_ix] = codes[full_ix[axis]]
      end
    when ndim
      unless codes.shape == h_shape
        raise ArgumentError, "codes shape #{codes.shape} != h shape #{h_shape} (case B needs exact match)"
      end
      out[] = codes
    when ndim - 1
      band_shape = h_shape.dup; band_shape.delete_at(axis)
      unless codes.shape == band_shape
        raise ArgumentError, "codes shape #{codes.shape} != h shape without axis #{band_shape}"
      end
      iter_fiber_coords(h_shape) do |full_ix|
        band_ix = full_ix.dup; band_ix.delete_at(axis)
        out[*full_ix] = codes[*band_ix]
      end
    else
      raise ArgumentError, "codes.ndim=#{codes.ndim} not in {1, #{ndim-1}, #{ndim}}"
    end
    out
  end

  # Reference sum along `axis` with per-fiber grouping by `cat`. Naive: iterates
  # each output cell (K × band-coord), scans the reduce-axis fiber, accumulates
  # into out[c, band_coord]. Value dtype = h.data_type (like existing #sum).
  #
  # Mask contract per PROPOSAL §2.4:
  #   - codes mask on cell → that cell contributes to no group (excluded)
  #   - value mask on cell → that cell not counted (skipped)
  #   - empty group cell → sum identity 0 (unmasked; ERI contract, no UNDEF for sum)
  def sum_ref(h, cat, axis)
    k         = cat.labels.size
    full_c    = broadcast_codes(cat.codes, h.shape, axis)
    band      = h.shape.dup; band.delete_at(axis)
    out_shape = [k] + band
    out       = CArray.new(h.data_type, out_shape).fill(0)
    hm        = h.has_mask?     ? h.mask     : nil
    cm        = full_c.has_mask? ? full_c.mask : nil

    iter_fiber_coords(band) do |band_ix|
      h.shape[axis].times do |i|
        full_ix = band_ix.dup; full_ix.insert(axis, i)
        next if cm && cm[*full_ix]             # codes masked → excluded
        c = full_c[*full_ix]
        next if c < 0 || c >= k                # out-of-vocabulary → excluded
        next if hm && hm[*full_ix]             # value masked → skipped
        out_ix = [c] + band_ix
        out[*out_ix] = out[*out_ix] + h[*full_ix]
      end
    end
    out
  end

  # Yield every coord tuple in row-major order for the given shape. Empty shape
  # yields [] once (scalar coord).
  def iter_fiber_coords(shape)
    if shape.empty?
      yield []
      return
    end
    idx = Array.new(shape.size, 0)
    loop do
      yield idx.dup
      i = shape.size - 1
      while i >= 0
        idx[i] += 1
        break if idx[i] < shape[i]
        idx[i] = 0
        i -= 1
      end
      break if i < 0
    end
  end
end


class TestCategoricalReduceAxis < Test::Unit::TestCase
  # --- reference sanity ---------------------------------------------------

  def test_reference_case_A_matches_current_indexer_form
    # 1-D cat, h (6,2,3), axis 0 → equivalent to existing indexer form.
    h = CArray.float64(6, 2, 3) { |i, y, x| (i + 1).to_f + 0.01 * (y * 10 + x) }
    codes_1d = CArray.int32(6) { |i| [0, 0, 1, 1, 2, 2][i] }
    cat = CACategorical.from_codes(codes_1d, [:a, :b, :c])
    ref = CategoricalReduceAxisRef.sum_ref(h, cat, 0)
    assert_equal [3, 2, 3], ref.shape
    # Group 0 sums i=0..1 per (y,x), Group 1 sums i=2..3, Group 2 sums i=4..5
    2.times { |y| 3.times { |x|
      base = 0.01 * (y * 10 + x)
      assert_in_delta((1.0 + base) + (2.0 + base), ref[0, y, x], 1e-12, "g0 (#{y},#{x})")
      assert_in_delta((3.0 + base) + (4.0 + base), ref[1, y, x], 1e-12, "g1 (#{y},#{x})")
      assert_in_delta((5.0 + base) + (6.0 + base), ref[2, y, x], 1e-12, "g2 (#{y},#{x})")
    } }
  end

  def test_reference_case_B_per_fiber_independent
    # user's dream example: cat co-varies with h on all axes.
    h = CArray.float64(6, 2, 3) { |i, y, x| (i + 1).to_f + 0.01 * (y * 10 + x) }
    # Distinct codes for each (y,x) fiber.
    codes = CArray.int32(6, 2, 3) { |i, y, x|
      case [y, x]
      when [0, 0] then [0, 0, 1, 1, 2, 2][i]
      when [0, 1] then [0, 0, 0, 1, 1, 2][i]
      when [0, 2] then [0, 1, 1, 2, 2, 2][i]
      when [1, 0] then [0, 0, 1, 2, 2, 2][i]
      when [1, 1] then [0, 1, 2, 2, 2, 2][i]
      when [1, 2] then [0, 0, 0, 0, 1, 2][i]
      end
    }
    cat = CACategorical.from_codes(codes, [:a, :b, :c])
    ref = CategoricalReduceAxisRef.sum_ref(h, cat, 0)
    assert_equal [3, 2, 3], ref.shape
    # Spot check (y=0, x=1): codes = [0,0,0,1,1,2], vals = [1,2,3,4,5,6] + 0.01
    base = 0.01
    assert_in_delta 1.01 + 2.01 + 3.01, ref[0, 0, 1], 1e-12
    assert_in_delta 4.01 + 5.01,        ref[1, 0, 1], 1e-12
    assert_in_delta 6.01,               ref[2, 0, 1], 1e-12
    # Spot check (y=1, x=2): codes = [0,0,0,0,1,2], vals = [1..6] + 0.12
    assert_in_delta 1.12 + 2.12 + 3.12 + 4.12, ref[0, 1, 2], 1e-12
    assert_in_delta 5.12,                       ref[1, 1, 2], 1e-12
    assert_in_delta 6.12,                       ref[2, 1, 2], 1e-12
  end

  def test_reference_band_only_land_cover_pattern
    # cat shape (2,3) — one class per (y,x), constant in time.
    h = CArray.float64(6, 2, 3) { |i, y, x| (i + 1).to_f }
    codes = CArray.int32(2, 3) { |y, x| (y * 3 + x) % 3 }
    cat = CACategorical.from_codes(codes, [:land, :sea, :ice])
    ref = CategoricalReduceAxisRef.sum_ref(h, cat, 0)
    assert_equal [3, 2, 3], ref.shape
    # Each fiber (y,x) sums h[:,y,x] = 1+2+..+6 = 21 into a single bin cat[y,x]
    2.times { |y| 3.times { |x|
      c = (y * 3 + x) % 3
      3.times do |cc|
        expected = (cc == c) ? 21.0 : 0.0
        assert_in_delta expected, ref[cc, y, x], 1e-12, "cell (#{cc},#{y},#{x})"
      end
    } }
  end

  def test_reference_mask_on_value_skips_cell
    h = CArray.float64(6, 2, 3) { |i, y, x| (i + 1).to_f }
    h[0, 0, 0] = UNDEF   # mask 1 cell
    codes_1d = CArray.int32(6) { |i| i / 2 }  # [0,0,1,1,2,2]
    cat = CACategorical.from_codes(codes_1d, [:a, :b, :c])
    ref = CategoricalReduceAxisRef.sum_ref(h, cat, 0)
    # (y=0, x=0): group 0 excludes h[0], so only h[1]=2 contributes → 2.0 (not 3.0)
    assert_in_delta 2.0, ref[0, 0, 0], 1e-12
    # Other cells unaffected: group 0 at (y,x)=(0,1) = h[0,0,1]+h[1,0,1] = 1+2 = 3
    assert_in_delta 3.0, ref[0, 0, 1], 1e-12
  end

  def test_reference_empty_group_returns_zero_identity
    # ERI contract: fiber with no cell in group c → sum = 0 (identity, unmasked)
    h = CArray.float64(6, 2, 3) { |i, y, x| (i + 1).to_f }
    codes_1d = CArray.int32(6) { 0 }  # all cells in group 0
    cat = CACategorical.from_codes(codes_1d, [:a, :b, :c])
    ref = CategoricalReduceAxisRef.sum_ref(h, cat, 0)
    # groups 1, 2 have no cells anywhere
    2.times { |y| 3.times { |x|
      assert_in_delta 0.0, ref[1, y, x], 1e-12
      assert_in_delta 0.0, ref[2, y, x], 1e-12
    } }
  end

  # --- integration: kernel path vs reference -------------------------------

  def test_sum_axis_case_A_parity
    h = CArray.float64(6, 2, 3) { |i, y, x| (i + 1).to_f + 0.01 * (y * 10 + x) }
    codes_1d = CArray.int32(6) { |i| [0, 0, 1, 1, 2, 2][i] }
    cat = CACategorical.from_codes(codes_1d, [:a, :b, :c])
    ref = CategoricalReduceAxisRef.sum_ref(h, cat, 0)
    out = h.group_by_category(cat).sum(axis: 0)
    assert_equal ref.shape, out.shape
    assert_carray_close ref, out
  end

  def test_sum_axis_case_B_parity
    h = CArray.float64(6, 2, 3) { |i, y, x| (i + 1).to_f + 0.01 * (y * 10 + x) }
    codes = CArray.int32(6, 2, 3) { |i, y, x|
      case [y, x]
      when [0, 0] then [0, 0, 1, 1, 2, 2][i]
      when [0, 1] then [0, 0, 0, 1, 1, 2][i]
      when [0, 2] then [0, 1, 1, 2, 2, 2][i]
      when [1, 0] then [0, 0, 1, 2, 2, 2][i]
      when [1, 1] then [0, 1, 2, 2, 2, 2][i]
      when [1, 2] then [0, 0, 0, 0, 1, 2][i]
      end
    }
    cat = CACategorical.from_codes(codes, [:a, :b, :c])
    ref = CategoricalReduceAxisRef.sum_ref(h, cat, 0)
    out = h.group_by_category(cat).sum(axis: 0)
    assert_equal ref.shape, out.shape
    assert_carray_close ref, out
  end

  def test_sum_axis_band_only_parity
    h = CArray.float64(6, 2, 3) { |i, y, x| (i + 1).to_f }
    codes = CArray.int32(2, 3) { |y, x| (y * 3 + x) % 3 }
    cat = CACategorical.from_codes(codes, [:land, :sea, :ice])
    ref = CategoricalReduceAxisRef.sum_ref(h, cat, 0)
    out = h.group_by_category(cat).sum(axis: 0)
    assert_equal ref.shape, out.shape
    assert_carray_close ref, out
  end

  def test_sum_axis_value_mask_parity
    h = CArray.float64(6, 2, 3) { |i, y, x| (i + 1).to_f }
    h[0, 0, 0] = UNDEF
    h[3, 1, 2] = UNDEF
    codes_1d = CArray.int32(6) { |i| i / 2 }
    cat = CACategorical.from_codes(codes_1d, [:a, :b, :c])
    ref = CategoricalReduceAxisRef.sum_ref(h, cat, 0)
    out = h.group_by_category(cat).sum(axis: 0)
    assert_carray_close ref, out
  end

  def test_sum_axis_codes_mask_parity
    # Sentinel-based exclusion: from_codes auto-masks the type-max sentinel.
    h = CArray.float64(6, 2, 3) { |i, y, x| (i + 1).to_f }
    codes = CArray.int32(6, 2, 3) { |i, y, x| i / 2 }
    codes[0, 0, 0] = 0xFFFFFFFF   # will be masked by from_codes (signed -1 read)
    # Wait — CA_INT32 sentinel is -1 (signed). Set via -1.
    codes[0, 0, 0] = -1
    cat = CACategorical.from_codes(codes, [:a, :b, :c])
    ref = CategoricalReduceAxisRef.sum_ref(h, cat, 0)
    out = h.group_by_category(cat).sum(axis: 0)
    assert_carray_close ref, out
  end

  # --- backward compat -----------------------------------------------------

  def test_backward_compat_no_axis_unchanged
    # axis: omitted → current full-collapse behavior, byte-identical to before.
    h = CArray.float64(6, 2, 3) { |i, y, x| (i + 1).to_f + 0.01 * (y * 10 + x) }
    codes = CArray.int32(6, 2, 3) { |i, y, x| i / 2 }
    cat = CACategorical.from_codes(codes, [:a, :b, :c])
    out = h.group_by_category(cat).sum
    assert_equal [3], out.shape
    # Full collapse over 36 cells, group 0 = i in {0,1} × 6 fibers → 12 cells
    expected = 0.0
    36.times do |flat|
      i = flat / 6
      y = (flat % 6) / 3
      x = flat % 3
      expected += (i + 1) + 0.01 * (y * 10 + x) if i / 2 == 0
    end
    assert_in_delta expected, out[0], 1e-9
  end

  # --- shape rule violations ----------------------------------------------

  def test_shape_rule_mid_ndim_cat_raises
    # cat.ndim = 2 for h.ndim = 3 → does NOT match A (ndim=1), B (ndim=3), or
    # band-only (ndim=2 = 3-1) with size fit → but shape (6, 2) ≠ h without axis 0
    # (which would be (2, 3)). So this is a genuine mismatch.
    h = CArray.float64(6, 2, 3) { 0.0 }
    codes = CArray.int32(6, 2) { |i, y| 0 }
    cat = CACategorical.from_codes(codes, [:a, :b, :c])
    err = assert_raise(ArgumentError) { h.group_by_category(cat).sum(axis: 0) }
    # Message should surface h.shape, cat.shape, axis, and the 3 rule cases
    msg = err.message
    assert msg =~ /cat|categorical/i,     "message mentions cat: #{msg}"
    assert msg.include?("6"),              "message includes cat shape"
    assert msg.include?("3"),              "message includes h shape"
  end

  def test_shape_rule_case_A_size_mismatch_raises
    h = CArray.float64(6, 2, 3) { 0.0 }
    codes_1d = CArray.int32(5) { 0 }  # wrong size for axis 0 (=6)
    cat = CACategorical.from_codes(codes_1d, [:a, :b, :c])
    assert_raise(ArgumentError) { h.group_by_category(cat).sum(axis: 0) }
  end

  # --- deferred: order stats raise cleanly with axis: ---------------------

  def test_axis_on_true_order_stat_raises_deferred_message
    # median / percentile need a sort per group (genuine order statistics) and
    # stay deferred to a future demand-driven phase; variance / stddev /
    # variancep / stddevp are 2-pass centred aggregates (no order needed) and
    # land in Phase 2 (see PROPOSAL §5).
    h = CArray.float64(6, 2, 3) { |i, y, x| (i + 1).to_f }
    codes = CArray.int32(6, 2, 3) { |i, y, x| i / 2 }
    cat = CACategorical.from_codes(codes, [:a, :b, :c])
    grp = h.group_by_category(cat)
    err = assert_raise(NotImplementedError) { grp.median(axis: 0) }
    assert err.message =~ /axis.*deferred|Phase 4|order stat/i
    err = assert_raise(NotImplementedError) { grp.percentile(50.0, axis: 0) }
    assert err.message =~ /axis.*deferred|Phase 4|order stat/i
  end

  # --- Phase 2: mean / min / max / minmax / count / prod ---------------------

  def h_and_cat_case_B_with_gaps
    # A case-B setup that also exercises empty groups (fiber (1,0) has all
    # cells in group 0 → groups 1 and 2 empty there).
    h = CArray.float64(6, 2, 3) { |i, y, x| (i + 1).to_f + 0.01 * (y * 10 + x) }
    codes = CArray.int32(6, 2, 3) { |i, y, x|
      case [y, x]
      when [0, 0] then [0, 0, 1, 1, 2, 2][i]
      when [0, 1] then [0, 0, 0, 1, 1, 2][i]
      when [0, 2] then [0, 1, 1, 2, 2, 2][i]
      when [1, 0] then [0, 0, 0, 0, 0, 0][i]   # empty groups 1, 2
      when [1, 1] then [0, 1, 2, 2, 2, 2][i]
      when [1, 2] then [0, 0, 0, 0, 1, 2][i]
      end
    }
    cat = CACategorical.from_codes(codes, [:a, :b, :c])
    [h, cat]
  end

  def test_mean_axis_case_B_parity_and_empty
    h, cat = h_and_cat_case_B_with_gaps
    ref = CategoricalReduceAxisRef.mean_ref(h, cat, 0)
    out = h.group_by_category(cat).mean(axis: 0)
    assert_carray_close ref, out
    # Empty groups at (1,0): should be masked
    assert out.mask[1, 1, 0], "empty group 1 at (1,0) masked"
    assert out.mask[2, 1, 0], "empty group 2 at (1,0) masked"
  end

  def test_min_max_axis_case_B_parity_and_empty
    h, cat = h_and_cat_case_B_with_gaps
    min_ref_arr = CategoricalReduceAxisRef.min_ref(h, cat, 0)
    max_ref_arr = CategoricalReduceAxisRef.max_ref(h, cat, 0)
    grp = h.group_by_category(cat)
    assert_carray_close min_ref_arr, grp.min(axis: 0)
    assert_carray_close max_ref_arr, grp.max(axis: 0)
    # Empty groups masked in min AND max
    assert grp.min(axis: 0).mask[1, 1, 0]
    assert grp.max(axis: 0).mask[2, 1, 0]
  end

  def test_minmax_axis_returns_pair
    h, cat = h_and_cat_case_B_with_gaps
    pair = h.group_by_category(cat).minmax(axis: 0)
    assert_kind_of Array, pair
    assert_equal 2, pair.size
    assert_carray_close CategoricalReduceAxisRef.min_ref(h, cat, 0), pair[0]
    assert_carray_close CategoricalReduceAxisRef.max_ref(h, cat, 0), pair[1]
  end

  def test_count_axis_case_B_parity
    h, cat = h_and_cat_case_B_with_gaps
    h[0, 0, 0] = UNDEF   # mask 1 cell
    ref = CategoricalReduceAxisRef.count_ref(h, cat, 0)
    out = h.group_by_category(cat).count_not_masked(axis: 0)
    assert_equal ref.shape, out.shape
    assert_equal ref.to_a, out.to_a
    # count() no-arg with axis: should behave same as count_not_masked
    assert_equal ref.to_a, h.group_by_category(cat).count(axis: 0).to_a
  end

  def test_prod_axis_case_B_parity_and_empty_identity
    h, cat = h_and_cat_case_B_with_gaps
    ref = CategoricalReduceAxisRef.prod_ref(h, cat, 0)
    out = h.group_by_category(cat).prod(axis: 0)
    assert_carray_close ref, out
    # Empty groups → 1.0 (identity)
    assert_in_delta 1.0, out[1, 1, 0], 1e-12
    assert_in_delta 1.0, out[2, 1, 0], 1e-12
  end

  def test_deferred_count_masked_and_count_v_raise
    h, cat = h_and_cat_case_B_with_gaps
    grp = h.group_by_category(cat)
    err = assert_raise(NotImplementedError) { grp.count_masked(axis: 0) }
    assert err.message =~ /not implemented/i
    err = assert_raise(NotImplementedError) { grp.count(0, axis: 0) }
    assert err.message =~ /not implemented/i
  end

  def test_moments_cache_hit_for_same_axis
    # sum + mean + min + max at the same axis should share the moments cache
    # (invisible for correctness; visible if we peek at internals).
    h, cat = h_and_cat_case_B_with_gaps
    grp = h.group_by_category(cat)
    grp.sum(axis: 0)
    cache1 = grp.instance_variable_get(:@axis_moments_cache)
    grp.mean(axis: 0)
    cache2 = grp.instance_variable_get(:@axis_moments_cache)
    # Same object identity for axis 0 entry (not rebuilt)
    assert_equal cache1[0].object_id, cache2[0].object_id
  end

  def test_axis_case_A_parity_family
    # 1-D cat, broadcast across (y,x). All Phase 2 methods should work.
    h = CArray.float64(6, 2, 3) { |i, y, x| (i + 1).to_f + 0.01 * (y * 10 + x) }
    codes_1d = CArray.int32(6) { |i| i / 2 }  # [0,0,1,1,2,2]
    cat = CACategorical.from_codes(codes_1d, [:a, :b, :c])
    grp = h.group_by_category(cat)
    assert_carray_close CategoricalReduceAxisRef.min_ref(h, cat, 0),  grp.min(axis: 0)
    assert_carray_close CategoricalReduceAxisRef.max_ref(h, cat, 0),  grp.max(axis: 0)
    assert_carray_close CategoricalReduceAxisRef.mean_ref(h, cat, 0), grp.mean(axis: 0)
    assert_carray_close CategoricalReduceAxisRef.prod_ref(h, cat, 0), grp.prod(axis: 0)
    assert_equal        CategoricalReduceAxisRef.count_ref(h, cat, 0).to_a,
                        grp.count_not_masked(axis: 0).to_a
  end

  def test_variance_stddev_axis_parity_case_B
    # Reference: per (c, fiber) compute variance / stddev directly from the list
    # of contributing values, using CArray's own scalar formulas.
    h, cat = h_and_cat_case_B_with_gaps
    r = CategoricalReduceAxisRef.per_cell_values(h, cat, 0)
    k = r[:k]; band = r[:band]
    var_ref  = CArray.float64(*([k] + band))
    varp_ref = CArray.float64(*([k] + band))
    CategoricalReduceAxisRef.iter_fiber_coords(band) do |band_ix|
      k.times do |c|
        vs = r[:values][[c] + band_ix]
        n  = vs.size
        if n == 0
          var_ref[c, *band_ix]  = UNDEF
          varp_ref[c, *band_ix] = UNDEF
        elsif n == 1
          var_ref[c, *band_ix]  = 0.0
          varp_ref[c, *band_ix] = 0.0
        else
          mean = vs.sum(0.0) / n
          ss   = vs.map { |v| (v - mean) ** 2 }.sum(0.0)
          var_ref[c, *band_ix]  = ss / (n - 1)
          varp_ref[c, *band_ix] = ss / n
        end
      end
    end
    grp = h.group_by_category(cat)
    assert_carray_close var_ref,       grp.variance(axis: 0),  1e-9
    assert_carray_close varp_ref,      grp.variancep(axis: 0), 1e-9
    # stddev / stddevp = sqrt of variance / variancep
    sd_ref  = var_ref.sqrt
    sdp_ref = varp_ref.sqrt
    assert_carray_close sd_ref,  grp.stddev(axis: 0),  1e-9
    assert_carray_close sdp_ref, grp.stddevp(axis: 0), 1e-9
  end

  def test_variance_axis_empty_and_single_cell_contracts
    # Empty group → UNDEF (both variance and variancep); single cell → 0.0.
    h = CArray.float64(6, 2, 3) { |i, y, x| (i + 1).to_f }
    # Set codes so group 2 has 1 cell at (0,0) and 0 cells at (0,1)
    codes = CArray.int32(6, 2, 3) { |i, y, x|
      case [y, x]
      when [0, 0] then [0, 0, 2, 1, 1, 1][i]   # group 2 has exactly 1 cell
      when [0, 1] then [0, 0, 0, 1, 1, 1][i]   # group 2 has 0 cells
      else             i / 3
      end
    }
    cat = CACategorical.from_codes(codes, [:a, :b, :c])
    grp = h.group_by_category(cat)
    var = grp.variance(axis: 0)
    assert_in_delta 0.0, var[2, 0, 0], 1e-12,           "single-cell → 0.0"
    assert var.has_mask? && var.mask[2, 0, 1],          "empty → UNDEF"
  end

  # --- Phase 3: wsum / wmean ---------------------------------------------

  def test_wsum_wmean_axis_case_B_parity_and_empty
    h, cat = h_and_cat_case_B_with_gaps
    weights = CArray.float64(*h.shape) { |i, y, x| (1 + (i + y + x) % 3).to_f }
    ws_ref, wm_ref = CategoricalReduceAxisRef.wsum_wmean_ref(h, cat, weights, 0)
    grp = h.group_by_category(cat)
    assert_carray_close ws_ref, grp.wsum(weights, axis: 0), 1e-9
    assert_carray_close wm_ref, grp.wmean(weights, axis: 0), 1e-9
    # Empty groups at (1,0): wsum=0.0 (identity, unmasked), wmean=UNDEF
    assert_in_delta 0.0, grp.wsum(weights, axis: 0)[1, 1, 0], 1e-12
    assert grp.wmean(weights, axis: 0).mask[1, 1, 0], "empty group wmean masked"
  end

  def test_wsum_wmean_axis_h_mask_and_w_mask
    h, cat = h_and_cat_case_B_with_gaps
    weights = CArray.float64(*h.shape) { |i, y, x| 1.0 + i * 0.1 }
    h[0, 0, 0]       = UNDEF  # mask 1 h cell
    weights[3, 1, 2] = UNDEF  # mask 1 weight cell
    ws_ref, wm_ref = CategoricalReduceAxisRef.wsum_wmean_ref(h, cat, weights, 0)
    grp = h.group_by_category(cat)
    assert_carray_close ws_ref, grp.wsum(weights, axis: 0), 1e-9
    assert_carray_close wm_ref, grp.wmean(weights, axis: 0), 1e-9
  end

  def test_wsum_wmean_axis_case_A_broadcast_weights
    # 1-D cat, but weights must match source.shape → require explicit broadcast.
    h = CArray.float64(6, 2, 3) { |i, y, x| (i + 1).to_f }
    codes_1d = CArray.int32(6) { |i| i / 2 }
    cat = CACategorical.from_codes(codes_1d, [:a, :b, :c])
    # Weights as 1-D repeat across (y, x)
    w_1d = CArray.float64(6) { |i| 1.0 + i * 0.5 }
    w_full = w_1d.reshape(6, 1, 1).broadcast_to(6, 2, 3)
    ws_ref, wm_ref = CategoricalReduceAxisRef.wsum_wmean_ref(h, cat, w_full, 0)
    grp = h.group_by_category(cat)
    assert_carray_close ws_ref, grp.wsum(w_full, axis: 0), 1e-9
    assert_carray_close wm_ref, grp.wmean(w_full, axis: 0), 1e-9
  end

  def test_wsum_wmean_axis_weights_shape_mismatch_raises
    # rev3: weights must match source shape exactly (no implicit broadcast).
    h = CArray.float64(6, 2, 3) { 1.0 }
    codes_1d = CArray.int32(6) { |i| i / 2 }
    cat = CACategorical.from_codes(codes_1d, [:a, :b, :c])
    w_1d = CArray.float64(6) { 1.0 }   # shape [6], NOT h.shape [6, 2, 3]
    err = assert_raise(ArgumentError) {
      h.group_by_category(cat).wsum(w_1d, axis: 0)
    }
    assert err.message =~ /weights.*shape|broadcast_to/i, err.message
  end

  def test_axis_band_only_parity_family
    h = CArray.float64(6, 2, 3) { |i, y, x| (i + 1).to_f }
    codes = CArray.int32(2, 3) { |y, x| (y * 3 + x) % 3 }
    cat = CACategorical.from_codes(codes, [:land, :sea, :ice])
    grp = h.group_by_category(cat)
    assert_carray_close CategoricalReduceAxisRef.min_ref(h, cat, 0),  grp.min(axis: 0)
    assert_carray_close CategoricalReduceAxisRef.max_ref(h, cat, 0),  grp.max(axis: 0)
    assert_carray_close CategoricalReduceAxisRef.mean_ref(h, cat, 0), grp.mean(axis: 0)
    assert_carray_close CategoricalReduceAxisRef.prod_ref(h, cat, 0), grp.prod(axis: 0)
  end

  # --- helper --------------------------------------------------------------

  def assert_carray_close(a, b, tol = 1e-10)
    assert_equal a.shape, b.shape, "shape"
    # Trivial (all-zero) masks are equivalent to no mask — the reference
    # helpers only create a mask on UNDEF assignment (skipped when no empty
    # groups), whereas the C kernels may pre-create a mask unconditionally.
    # mask.to_a returns Integer 0/1 (bulk path predates Kleene scalar changes).
    # Treat "has_mask? but all zero" as unmasked so kernel-preallocated masks
    # match reference outputs that lazily create masks only on UNDEF assignment.
    to_bool = ->(x) { x != 0 && x != false }
    a_mask = a.has_mask? ? a.mask.to_a.flatten.map(&to_bool) : nil
    b_mask = b.has_mask? ? b.mask.to_a.flatten.map(&to_bool) : nil
    a_mask = nil if a_mask && a_mask.none?
    b_mask = nil if b_mask && b_mask.none?
    if a_mask || b_mask
      assert_equal (a_mask || Array.new(a.elements, false)),
                   (b_mask || Array.new(b.elements, false)),
                   "mask pattern"
      mflat = a_mask || b_mask
      aflat = a.value.to_a.flatten
      bflat = b.value.to_a.flatten
      max_diff = 0.0
      aflat.each_with_index do |av, i|
        next if mflat[i]
        d = (av - bflat[i]).abs
        max_diff = d if d > max_diff
      end
      assert max_diff < tol, "max abs diff #{max_diff} > #{tol} (unmasked cells only)"
    else
      diff = (a - b).abs.max
      assert diff < tol, "max abs diff #{diff} > #{tol}"
    end
  end
end

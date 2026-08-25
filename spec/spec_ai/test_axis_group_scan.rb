# Differential test for the axis-group segment scan: the per-element-emit
# sibling of __axis_group_reduce__.  Exercises CAGroupIterator#cumsum / #cumprod
# / #cummax / #cummin / #cumcount with axis: :group against an independent
# pure-Ruby reference, over int + float + object dtypes, masks, excluded
# (fixed-vocabulary) cells, single group axis, multiple group slots, rank-N
# categoricals, band-preserving and flat groupings.
#
# Reference (no kernel): a scan preserves the source shape; within each group
# the running statistic accumulates in row-major position order along the
# grouped axes, per band.  That reduces to: walk the cells in full row-major
# flat order, key = (band coordinates, composite group code), maintain a running
# statistic per key.
#
# Masked / excluded policy matches the core CArray scan (this is the whole point
# of the family): a cell masked WITHIN its group does not update the accumulator
# but HOLDS the current running value, and its output is NOT masked -- for cumsum
# / cumprod / cumcount (identity 0 / 1 / 0) always, for cummax / cummin (no
# identity) only once a member has been seen, else UNDEF (the empty-max/min
# reduction contract).  A cell excluded from every group (composite code out of
# range) belongs to no group and is UNDEF.  cumcount is the 1-based running count
# of present cells.  Object cumsum / cumprod use the same identity 0 / 1 (like
# the core object scan); object cummax / cummin seed from the first member.

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../ext", __dir__)
require "test/unit"
require "carray"
require "bigdecimal"

class TestAxisGroupScan < Test::Unit::TestCase

  EPS = 1e-12

  OPS = [:cumsum, :cumprod, :cummax, :cummin, :cumcount]

  # Additive / multiplicative identity for the identity-bearing ops (0 / 1),
  # matching both the core scan and the kernel.  Integer 0 / 1 promote under +
  # / * to a Float or BigDecimal element's class.
  IDENT = { cumsum: 0, cumprod: 1 }.freeze

  # Fold one value into a running accumulator for `op` (no seeding logic here;
  # the caller seeds identity ops from IDENT and extrema from the first member).
  def fold(op, acc, v)
    case op
    when :cumsum  then acc + v
    when :cumprod then acc * v
    when :cummax  then v > acc ? v : acc
    when :cummin  then v < acc ? v : acc
    end
  end

  # Independent pure-Ruby scan reference.  Returns a source-shaped nested Array
  # (nil = UNDEF cell).  `slots` is the axis_group slot list (CACategorical or
  # nil); `op` is one of OPS.  Mirrors the core scan: a cell masked within its
  # group HOLDS the running value (identity ops always; extrema once seen, else
  # UNDEF); only a cell excluded from every group is UNDEF.  cumcount is 1-based.
  def ref(arr, slots, op)
    shape = arr.shape
    meta = []
    cur = 0
    slots.each do |s|
      if s.nil?
        meta << { kind: :band, axis: cur }; cur += 1
      else
        r = s.ndim
        meta << { kind: :group, axes: (cur...cur + r).to_a, cat: s }; cur += r
      end
    end
    band_axes  = meta.select { |m| m[:kind] == :band }.map { |m| m[:axis] }
    group_meta = meta.select { |m| m[:kind] == :group }

    out     = Array.new(arr.elements)      # flat, then reshape at the end
    running = {}                            # key -> running statistic
    count   = Hash.new(0)                   # key -> 1-based present count
    seen    = {}                            # key -> a member has been seen (extrema)
    idx  = Array.new(arr.ndim, 0)
    flat = 0
    arr.elements.times do
      masked = arr.has_mask? && arr.mask[*idx]
      # composite group code, computed independently of the source mask; a code
      # out of range means the cell belongs to no group (excluded).
      code = 0
      excluded = false
      group_meta.each do |m|
        sub = 0
        m[:axes].each { |a| sub = sub * shape[a] + idx[a] }
        c = m[:cat].codes[sub]
        k = m[:cat].labels.size
        if c.equal?(UNDEF) || c < 0 || c >= k
          excluded = true; break
        end
        code = code * k + c
      end
      if excluded
        out[flat] = nil
      else
        band_key = band_axes.map { |a| idx[a] }
        key = [band_key, code]
        case op
        when :cumcount
          count[key] += 1 unless masked      # 1-based running present count
          out[flat] = count[key]             # masked cell holds the count
        when :cumsum, :cumprod
          running[key] = IDENT[op] unless running.key?(key)   # identity-seeded
          running[key] = fold(op, running[key], arr[*idx]) unless masked
          out[flat] = running[key]           # masked cell holds the acc, unmasked
        when :cummax, :cummin
          if masked
            out[flat] = seen[key] ? running[key] : nil   # hold once seen, else UNDEF
          else
            running[key] = seen[key] ? fold(op, running[key], arr[*idx]) : arr[*idx]
            seen[key] = true
            out[flat] = running[key]
          end
        end
      end
      flat += 1
      (arr.ndim - 1).downto(0) do |k|
        idx[k] += 1; break if idx[k] < shape[k]; idx[k] = 0
      end
    end
    nest(out, shape)
  end

  def nest(flat, shape)
    return flat[0] if shape.empty?
    return flat.dup if shape.size == 1
    inner = shape[1..]
    stride = inner.inject(1, :*)
    (0...shape[0]).map { |i| nest(flat[i * stride, stride], inner) }
  end

  # Compare a source-shaped CArray result against a nested-Array reference.
  # cumcount = integer running count; cummax / cummin = element selection (exact,
  # any dtype); cumsum / cumprod = arithmetic (exact for object, epsilon float).
  def assert_scan(exp, act, op, exact, msg = nil)
    fe = exp.flatten
    fa = act.to_a.flatten
    assert_equal fe.size, fa.size, "size #{msg}"
    fe.zip(fa).each_with_index do |(x, y), i|
      y = nil if y.equal?(UNDEF)
      if x.nil? || y.nil?
        assert_equal x, y, "cell #{i} nil mismatch #{msg} (#{op})"
      elsif op == :cumcount
        assert_equal x.to_i, y, "cell #{i} #{msg} (#{op})"
      elsif exact
        assert_equal x, y, "cell #{i} #{msg} (#{op})"
      else
        assert_in_delta x.to_f, y.to_f, EPS * (1 + x.abs), "cell #{i} #{msg} (#{op})"
      end
    end
  end

  # Run every scan op for one (array, slots) pair.  `object` sources compare
  # exactly for all ops; numeric sources compare exactly for cummax / cummin
  # (element selection) but with epsilon for cumsum / cumprod (float arithmetic).
  def check(arr, slots, msg, object: false)
    it = arr[*slots]
    OPS.each do |op|
      exact = object || op == :cummax || op == :cummin
      assert_scan ref(arr, slots, op), it.send(op, axis: :group), op, exact, msg
    end
  end

  # ---- 1-D flat (all axes grouped) -----------------------------------------

  def test_1d_flat_all_ops
    v   = CArray.float64(6) { |i| i + 1.0 }
    mon = (CArray.int32(6) { |i| [0, 1, 2, 0, 1, 2][i] }).categorize
    check(v, [mon], "1d flat float")
  end

  def test_1d_int_dtype
    v   = CArray.int32(8) { |i| (i * 3 + 1) % 7 }
    cat = (CArray.int32(8) { |i| i % 3 }).categorize
    check(v, [cat], "1d flat int32")
    assert_equal "int32",   v[cat].cummax(axis: :group).data_type_name
    assert_equal "int32",   v[cat].cummin(axis: :group).data_type_name
    assert_equal "float64", v[cat].cumsum(axis: :group).data_type_name
    assert_equal "float64", v[cat].cumprod(axis: :group).data_type_name
    assert_equal "int64",   v[cat].cumcount(axis: :group).data_type_name
  end

  def test_1d_uint8_dtype
    v   = CArray.uint8(10) { |i| (i * 5) % 11 }
    cat = (CArray.int32(10) { |i| i % 4 }).categorize
    check(v, [cat], "1d flat uint8")
    assert_equal "uint8", v[cat].cummax(axis: :group).data_type_name
  end

  # ---- object dtype --------------------------------------------------------

  def test_1d_object_integers
    v   = CArray.object(8) { |i| (i * 3 + 1) % 7 }
    cat = (CArray.int32(8) { |i| i % 3 }).categorize
    check(v, [cat], "1d flat object (Integer)", object: true)
    assert_equal "object", v[cat].cumsum(axis: :group).data_type_name
    assert_equal "object", v[cat].cummax(axis: :group).data_type_name
    assert_equal "int64",  v[cat].cumcount(axis: :group).data_type_name
  end

  def test_1d_object_bigdecimal
    v   = CArray.object(6) { |i| BigDecimal([3, 1, 4, 1, 5, 9][i].to_s) }
    cat = (CArray.int32(6) { |i| i % 2 }).categorize
    check(v, [cat], "1d flat object (BigDecimal)", object: true)
  end

  def test_object_band_preserving
    v   = CArray.object(6, 3) { |i, j| i * 3 + j + 1 }
    mon = (CArray.int32(6) { |i| [0, 1, 2, 0, 1, 2][i] }).categorize
    check(v, [mon, nil], "object band-preserving", object: true)
  end

  def test_object_rank2_with_band
    v = CArray.object(3, 4, 2) { |i, j, k| i * 8 + j * 2 + k + 1 }
    region_codes = CArray.int32(3, 4) { |i, j| (i * j) % 3 }
    cat = CACategorical.from_codes(region_codes, %w[a b c])
    check(v, [cat, nil], "object rank-2 + band", object: true)
  end

  # ---- band-preserving -----------------------------------------------------

  def test_2d_band_preserving
    v   = CArray.float64(6, 3) { |i, j| Math.sin(i) + j * 2 }
    mon = (CArray.int32(6) { |i| [0, 1, 2, 0, 1, 2][i] }).categorize
    check(v, [mon, nil], "2d band-preserving (group axis 0)")
  end

  def test_3d_band_preserving_month_grid
    # (time, lat, lon)-ish: group the leading axis by month, keep lat/lon bands.
    v   = CArray.float64(12, 4, 5) { |i, j, k| Math.cos(i * 0.3) + j + k * 0.1 }
    mon = (CArray.int32(12) { |i| i % 3 }).categorize
    check(v, [mon, nil, nil], "3d band-preserving month grid")
  end

  def test_band_is_leading_axis
    # group the trailing axis, keep the leading band axis
    v   = CArray.float64(3, 6) { |i, j| i * 10 + j }
    cat = (CArray.int32(6) { |j| [0, 0, 1, 1, 2, 2][j] }).categorize
    check(v, [nil, cat], "band leading, group trailing")
  end

  def test_int_band_preserving_extrema_dtype
    v   = CArray.int32(6, 3) { |i, j| (i * 7 + j * 3) % 11 }
    mon = (CArray.int32(6) { |i| i % 2 }).categorize
    check(v, [mon, nil], "int band-preserving extrema")
    assert_equal "int32", v[mon, nil].cummax(axis: :group).data_type_name
  end

  # ---- multiple group slots ------------------------------------------------

  def test_two_group_slots
    v = CArray.float64(4, 3) { |i, j| i + j * 0.5 + 1 }
    g0 = (CArray.int32(4) { |i| i % 2 }).categorize
    g1 = (CArray.int32(3) { |j| j % 2 }).categorize
    check(v, [g0, g1], "two group slots (flat, composite)")
  end

  def test_two_group_slots_with_band
    v  = CArray.float64(4, 3, 2) { |i, j, k| i + j + k * 0.25 }
    g0 = (CArray.int32(4) { |i| i % 2 }).categorize
    g1 = (CArray.int32(3) { |j| j % 2 }).categorize
    check(v, [g0, g1, nil], "two group slots + band")
  end

  # ---- rank-N categorical (one categorical consumes >1 axis) ---------------

  def test_rank2_categorical
    v = CArray.float64(3, 4) { |i, j| i * 4 + j + 1 }
    # a [3,4] region map -> 3 regions, collapsing both axes into one group axis
    region_codes = CArray.int32(3, 4) { |i, j| (i + j) % 3 }
    cat = CACategorical.from_codes(region_codes, [10, 20, 30])
    check(v, [cat], "rank-2 categorical (flat)")
  end

  def test_rank2_categorical_with_band
    v = CArray.float64(3, 4, 2) { |i, j, k| i * 8 + j * 2 + k + 1 }
    region_codes = CArray.int32(3, 4) { |i, j| (i * j) % 3 }
    cat = CACategorical.from_codes(region_codes, %w[a b c])
    check(v, [cat, nil], "rank-2 categorical + band")
  end

  # ---- masks + excluded (fixed-vocabulary) cells ---------------------------

  def test_masked_source_cells
    v = CArray.float64(8) { |i| i + 1.0 }
    v[2] = UNDEF
    v[5] = UNDEF
    cat = (CArray.int32(8) { |i| i % 3 }).categorize
    check(v, [cat], "masked source cells")
  end

  def test_masked_object_cells
    v = CArray.object(8) { |i| i + 1 }
    v[2] = UNDEF
    v[5] = UNDEF
    cat = (CArray.int32(8) { |i| i % 3 }).categorize
    check(v, [cat], "masked object cells", object: true)
  end

  def test_excluded_out_of_vocabulary
    # fixed vocabulary {0,1}: key 2 is out-of-vocabulary -> excluded (masked code)
    keys = CArray.int32(9) { |i| i % 3 }             # 0,1,2,0,1,2,...
    cat  = keys.categorize(labels: [0, 1])           # code for key 2 -> sentinel
    v    = CArray.float64(9) { |i| i + 1.0 }
    check(v, [cat], "excluded out-of-vocabulary cells")
  end

  def test_masked_and_excluded_band
    v = CArray.float64(6, 2) { |i, j| i * 2 + j + 1.0 }
    v[1, 0] = UNDEF
    keys = CArray.int32(6) { |i| i % 4 }
    cat  = keys.categorize(labels: [0, 1, 2])        # key 3 excluded
    check(v, [cat, nil], "masked + excluded, band-preserving")
  end

  def test_all_masked_group
    # a group whose every member is masked: the identity ops (cumsum / cumprod /
    # cumcount) hold their identity everywhere (unmasked), the extrema stay UNDEF
    v = CArray.float64(6) { |i| i + 1.0 }
    cat = (CArray.int32(6) { |i| i % 2 }).categorize
    [1, 3, 5].each { |i| v[i] = UNDEF }              # the whole odd group
    check(v, [cat], "all-masked group")
  end

  def test_empty_group_identity_and_undef
    # explicit pin of the empty-group (all-masked) outcome per op.
    v   = CArray.float64(6) { |i| i + 1.0 }
    cat = (CArray.int32(6) { |i| i % 2 }).categorize   # groups {0,2,4}, {1,3,5}
    [1, 3, 5].each { |i| v[i] = UNDEF }                # odd group fully masked
    g = v[cat]
    # identity ops: the empty group's cells carry the identity, unmasked.
    cs = g.cumsum(axis: :group)
    assert_equal [0, 0, 0], [cs[1], cs[3], cs[5]], "empty cumsum -> 0.0"
    assert_equal [false, false, false], cs.is_masked.to_a.values_at(1, 3, 5), "empty cumsum unmasked"
    cp = g.cumprod(axis: :group)
    assert_equal [1, 1, 1], [cp[1], cp[3], cp[5]], "empty cumprod -> 1.0"
    cc = g.cumcount(axis: :group)
    assert_equal [0, 0, 0], [cc[1], cc[3], cc[5]], "empty cumcount -> 0"
    assert_equal [false, false, false], cc.is_masked.to_a.values_at(1, 3, 5), "empty cumcount unmasked"
    # extrema: no member seen -> UNDEF everywhere in the empty group.
    [:cummax, :cummin].each do |op|
      r = g.send(op, axis: :group)
      assert_equal [true, true, true], r.is_masked.to_a.values_at(1, 3, 5), "empty #{op} -> UNDEF"
    end
    # the populated even group is unaffected (running sum of 1, 3, 5).
    assert_equal [1, 4, 9], [cs[0], cs[2], cs[4]], "even cumsum still runs"
  end

  # ---- strong invariant: single group == core scan cell-for-cell -----------

  # When every cell falls in ONE group, the group scan MUST equal the core
  # CArray#<op> scan of that array: same running accumulation, same masked-holds-
  # acc, same 1-based cumcount, same empty-extremum = UNDEF.  (Core cumulative
  # inits empty max/min to a type-min / -Inf sentinel; the group scan keeps the
  # empty-max = UNDEF reduction contract, so extrema are compared on the values
  # AFTER the first seen member, which both agree on.)
  def single_group(n)
    (CArray.int32(n) { 0 }).categorize     # one label -> all cells in group 0
  end

  def assert_single_group_matches_core(v)
    n   = v.elements
    cat = single_group(n)
    g   = v[cat]
    [:cumsum, :cumprod, :cumcount].each do |op|
      core  = v.send(op)
      group = g.send(op, axis: :group)
      # identity ops: cell-for-cell equal, both value and (never-masked) mask.
      assert_equal core.to_a, group.to_a, "single-group #{op} value == core"
      assert_equal core.is_masked.to_a, group.is_masked.to_a, "single-group #{op} mask == core"
    end
    [:cummax, :cummin].each do |op|
      core  = v.send(op).to_a
      group = g.send(op, axis: :group)
      gm    = group.is_masked.to_a
      gv    = group.to_a
      seen  = false
      n.times do |i|
        present = !v.is_masked[i]
        seen ||= present
        if seen
          assert_equal false, gm[i], "single-group #{op} seen cell #{i} unmasked"
          assert_equal core[i], gv[i], "single-group #{op} seen cell #{i} == core"
        else
          assert_equal true,  gm[i], "single-group #{op} pre-seen cell #{i} UNDEF"
        end
      end
    end
  end

  def test_single_group_matches_core_int
    [proc { CArray.int32(8) { |i| (i * 3 + 1) % 7 } },
     proc { CArray.int64(8) { |i| (i * 5 + 2) % 9 } }].each do |mk|
      base = mk.call
      # no mask, then leading / middle / trailing masks
      assert_single_group_matches_core(base)
      [[0], [3], [7], [0, 1], [6, 7], [0, 3, 7]].each do |mi|
        v = mk.call
        mi.each { |i| v[i] = UNDEF }
        assert_single_group_matches_core(v)
      end
    end
  end

  def test_single_group_matches_core_float
    mk = proc { CArray.float64(8) { |i| Math.sin(i) * 3 + i } }
    assert_single_group_matches_core(mk.call)
    [[0], [4], [7], [0, 1, 2], [5, 6, 7]].each do |mi|
      v = mk.call
      mi.each { |i| v[i] = UNDEF }
      assert_single_group_matches_core(v)
    end
  end

  # ---- no :group delegates to the plain value scan -------------------------

  def test_no_group_delegates
    v   = CArray.float64(6) { |i| i + 1.0 }
    cat = (CArray.int32(6) { |i| i % 2 }).categorize
    assert_equal v.cumsum.to_a,  v[cat].cumsum.to_a
    assert_equal v.cumprod.to_a, v[cat].cumprod.to_a
    assert_equal v.cummax.to_a,  v[cat].cummax.to_a
    assert_equal v.cummin.to_a,  v[cat].cummin.to_a
  end

  def test_fold_band_into_scan_rejected
    v   = CArray.float64(6, 2) { |i, j| i + j }
    cat = (CArray.int32(6) { |i| i % 2 }).categorize
    OPS.each do |op|
      assert_raise(ArgumentError) { v[cat, nil].send(op, axis: [:group, 1]) }
    end
  end

  # ---- flat vs band agreement (design-question pin) ------------------------

  def test_flat_matches_single_band
    # A grouping with one band of length 1 must match the flat grouping: the
    # band-preserving path (outer band iter) and the flat path (single slab)
    # walk the grouped axes in the same row-major order.
    v    = CArray.float64(6, 1) { |i, _| i + 1.0 }
    cat  = (CArray.int32(6) { |i| i % 2 }).categorize
    OPS.each do |op|
      band = v[cat, nil].send(op, axis: :group).to_a.flatten
      flat = v.reshape(6)[cat].send(op, axis: :group).to_a
      assert_equal flat, band, "flat vs band (#{op})"
    end
  end
end

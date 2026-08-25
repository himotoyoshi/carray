# Iterator-family segment-scan surface test (PROPOSAL_ITERATOR_FAMILY_PHASE4).
#
# The scan family (cumsum / cumprod / cummax / cummin / cumcount) is a "should"
# member of the CAIterator surface: a scan writes a per-cell running statistic,
# which is single-valued only when each cell belongs to exactly one piece.  The
# partition members (slab / block / categorical / group) PROVIDE it; the window
# member's OVERLAPPING windows put a cell in many windows, so it is the lone
# exemption (raise), exactly like map / sort_addr.
#
# This test pins three things:
#   (a) surface uniformity -- every iterator answers respond_to? for all 5 scans;
#   (b) each partition member computes the 5 scans correctly against an
#       independent pure-Ruby per-unit running reference (int + float, masks, and
#       the excluded-cell case for the classifying members);
#   (c) CAWindowIterator raises NotImplementedError for each scan name.
# Plus an object-dtype sanity check through CACategoricalIterator.
#
# Two reference engines, matching the two member engines -- and they now agree
# cell-for-cell on the shared conventions (the point of this alignment):
#   * slab / block delegate to the core value scan: identity-seeded (0 / 1), a
#     source-masked cell HOLDS the running accumulator (output never masked),
#     cumcount is the 1-based running count of present cells.
#   * categorical / group route through the axis-group scan with the SAME rule
#     keyed per group: cumsum / cumprod / cumcount hold their identity (masked
#     cell holds, unmasked; 1-based cumcount), cummax / cummin seed from each
#     group's first member and hold once seen (masked-before-seen -> UNDEF).  A
#     cell EXCLUDED from every group (out-of-vocabulary / masked code) is UNDEF.

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../ext", __dir__)
require "test/unit"
require "carray"
require "bigdecimal"

class TestIteratorScanSurface < Test::Unit::TestCase

  SCANS = [:cumsum, :cumprod, :cummax, :cummin, :cumcount].freeze
  # Identity seed for the core (slab / block) scan.
  IDENT = { cumsum: 0.0, cumprod: 1.0,
            cummax: -Float::INFINITY, cummin: Float::INFINITY }.freeze

  def fold(op, acc, v)
    case op
    when :cumsum  then acc + v
    when :cumprod then acc * v
    when :cummax  then v > acc ? v : acc
    when :cummin  then v < acc ? v : acc
    end
  end

  # Core-style scan over a 1-D [value, masked?] sequence (slab / block).
  # cumsum / cumprod / cumcount have an identity, so a masked cell holds the
  # current acc unmasked (0 / 1 / running count).  cummax / cummin have no
  # identity: their running extremum is undefined until the first present
  # cell, so a *leading* masked cell (before any present value) is UNDEF
  # (nil), while a masked cell after the first present value holds the
  # running extremum unmasked -- the same seen-gated rule as group_scan.
  def core_scan(seq, op)
    acc  = (op == :cumcount) ? 0 : IDENT[op]
    seen = false
    seq.map do |val, masked|
      if op == :cumcount
        acc += 1 unless masked
        acc
      elsif op == :cummax || op == :cummin
        if masked
          seen ? acc : nil
        else
          acc = seen ? fold(op, acc, val) : val
          seen = true
          acc
        end
      elsif masked
        acc
      else
        acc = fold(op, acc, val)
        acc
      end
    end
  end

  # Partition-group-style scan (categorical / group): keyed by group code, using
  # the SAME masked-holds-acc rule as the core scan (identity 0 / 1 for cumsum /
  # cumprod / cumcount; first-member seed for cummax / cummin).  A source-masked
  # in-group cell holds the running value unmasked (extrema only once seen, else
  # nil); a cell excluded from every group (code nil / out of [0,k)) is nil.
  # cumcount is the 1-based running count of present cells.  Emits in source order.
  def group_scan(vals, codes, k, masks, op)
    running = {}
    count   = Hash.new(0)
    seen    = {}
    vals.each_index.map do |i|
      c = codes[i]
      excluded = c.nil? || c < 0 || c >= k
      if excluded
        nil
      else
        masked = masks[i]
        case op
        when :cumcount
          count[c] += 1 unless masked
          count[c]
        when :cumsum, :cumprod
          running[c] = (op == :cumsum ? 0 : 1) unless running.key?(c)
          running[c] = fold(op, running[c], vals[i]) unless masked
          running[c]
        when :cummax, :cummin
          if masked
            seen[c] ? running[c] : nil
          else
            running[c] = seen[c] ? fold(op, running[c], vals[i]) : vals[i]
            seen[c] = true
            running[c]
          end
        end
      end
    end
  end

  # Flat (value, code, source-mask) triples for a categorical grouping.
  def flat_cat(v, cat)
    n  = v.elements
    vf = v.reshape(n)
    cf = cat.codes.reshape(cat.elements)
    k  = cat.labels.size
    vals  = (0...n).map { |i| vf[i] }
    masks = (0...n).map { |i| vf.is_masked[i] }
    codes = (0...n).map { |i| cf.is_masked[i] ? nil : cf[i] }
    [vals, codes, k, masks]
  end

  # Compare a source-shaped scan result against a flat reference (nil = the cell
  # must be UNDEF; a value = the cell must be unmasked and equal / in-delta).
  def assert_scan(exp_flat, act, op, exact, msg = "")
    af = act.to_a.flatten
    am = act.is_masked.to_a.flatten
    assert_equal exp_flat.size, af.size, "size #{msg} (#{op})"
    exp_flat.each_index do |i|
      x = exp_flat[i]
      if x.nil?
        assert_equal true,  am[i], "cell #{i} must be masked #{msg} (#{op})"
      else
        assert_equal false, am[i], "cell #{i} must be unmasked #{msg} (#{op})"
        y = af[i]
        if op == :cumcount
          assert_equal x.to_i, y, "cell #{i} #{msg} (#{op})"
        elsif exact
          assert_equal x, y, "cell #{i} #{msg} (#{op})"
        else
          assert_in_delta x.to_f, y.to_f, 1e-9 * (1 + x.abs), "cell #{i} #{msg} (#{op})"
        end
      end
    end
  end

  # ---- (a) surface uniformity ---------------------------------------------

  def build_one_of_each
    a    = CArray.float64(6, 4) { |i, j| i + j + 1.0 }
    cat  = (CArray.int32(6) { |i| i % 2 }).categorize
    {
      "CASlabIterator"        => a[nil, :>],
      "CABlockIterator"       => a.blocks(2, 2),
      "CACategoricalIterator" => CArray.float64(6) { |i| i + 1.0 }.group_by_category(cat),
      "CAGroupIterator"       => CArray.float64(6) { |i| i + 1.0 }[cat],
      "CAWindowIterator"      => a.windows(-1..1, -1..1),
    }
  end

  def test_surface_uniformity
    build_one_of_each.each do |name, it|
      assert_equal name, it.class.name
      SCANS.each do |op|
        assert it.respond_to?(op), "#{name} must respond_to ##{op}"
      end
    end
  end

  # ---- (c) window raises ---------------------------------------------------

  def test_window_raises_each_scan
    win = CArray.float64(8) { |i| i + 1.0 }.windows(-1..1)
    SCANS.each do |op|
      assert_raise(NotImplementedError) { win.send(op) }
    end
    # 2-D window too.
    w2 = CArray.float64(4, 5) { |i, j| i + j }.windows(-1..1, -1..1)
    SCANS.each do |op|
      assert_raise(NotImplementedError) { w2.send(op) }
    end
  end

  # ---- (b) CASlabIterator --------------------------------------------------

  # Per-row (slab axis = last) core scan reference for a 2-D array.
  def slab_ref(m, op)
    n0, n1 = m.shape
    out = []
    (0...n0).each do |i|
      seq = (0...n1).map { |j| [m[i, j], m.is_masked[i, j]] }
      out.concat(core_scan(seq, op))
    end
    out
  end

  def test_slab_scan_int_and_float
    [CArray.int32(3, 5) { |i, j| (i * 5 + j) % 7 },
     CArray.float64(3, 5) { |i, j| Math.sin(i) + j }].each do |m|
      it = m[nil, :>]                                # slab axis = 1
      SCANS.each do |op|
        exact = op == :cummax || op == :cummin || op == :cumcount
        assert_scan slab_ref(m, op), it.send(op), op, exact, "slab #{m.data_type_name}"
      end
    end
  end

  def test_slab_scan_masked
    m = CArray.float64(3, 5) { |i, j| i * 5 + j + 1.0 }
    m[0, 2] = UNDEF                                  # interior masked cells
    m[1, 0] = UNDEF
    m[2, 3] = UNDEF
    it = m[nil, :>]
    SCANS.each do |op|
      exact = op == :cummax || op == :cummin || op == :cumcount
      assert_scan slab_ref(m, op), it.send(op), op, exact, "slab masked"
    end
  end

  def test_slab_scan_dtypes
    m = CArray.int32(3, 4) { |i, j| i + j }
    it = m[nil, :>]
    assert_equal "float64", it.cumsum.data_type_name
    assert_equal "float64", it.cumprod.data_type_name
    assert_equal "int32",   it.cummax.data_type_name
    assert_equal "int32",   it.cummin.data_type_name
    assert_equal "int64",   it.cumcount.data_type_name
  end

  def test_slab_multi_axis_scan_raises
    m = CArray.float64(3, 4, 2) { |i, j, k| i + j + k }
    it = m[nil, :>, :>]                              # 2-axis slab
    SCANS.each { |op| assert_raise(ArgumentError) { it.send(op) } }
  end

  # ---- (b) CABlockIterator -------------------------------------------------

  # 1-D block scan reference: split into tiles, core-scan each tile's cells
  # (row-major), concatenate.  A partial edge tile folds only its real cells.
  def block_ref_1d(src, b, op)
    n   = src.elements
    out = Array.new(n)
    lo  = 0
    while lo < n
      hi  = [lo + b, n].min
      seq = (lo...hi).map { |i| [src[i], src.is_masked[i]] }
      core_scan(seq, op).each_with_index { |v, t| out[lo + t] = v }
      lo += b
    end
    out
  end

  # 2-D block scan reference: per tile, gather real cells row-major, core-scan,
  # place back at their source positions (partial edge tiles fold fewer cells).
  def block_ref_2d(src, b0, b1, op)
    n0, n1 = src.shape
    out = Array.new(n0) { Array.new(n1) }
    ti = 0
    while ti * b0 < n0
      tj = 0
      while tj * b1 < n1
        rows = (ti * b0...[ti * b0 + b0, n0].min).to_a
        cols = (tj * b1...[tj * b1 + b1, n1].min).to_a
        seq  = []
        rows.each { |r| cols.each { |c| seq << [src[r, c], src.is_masked[r, c]] } }
        sc = core_scan(seq, op)
        k  = 0
        rows.each { |r| cols.each { |c| out[r][c] = sc[k]; k += 1 } }
        tj += 1
      end
      ti += 1
    end
    out.flatten
  end

  def test_block_scan_1d_int_and_float
    [CArray.int32(7) { |i| (i * 3 + 1) % 5 },
     CArray.float64(7) { |i| i + 1.0 }].each do |src|
      it = src.blocks(3)                             # tiles of 3, last partial (7 = 3+3+1)
      SCANS.each do |op|
        exact = op == :cummax || op == :cummin || op == :cumcount
        assert_scan block_ref_1d(src, 3, op), it.send(op), op, exact, "block1d #{src.data_type_name}"
      end
    end
  end

  def test_block_scan_2d_partial_edges
    src = CArray.int32(3, 3) { |i, j| i * 3 + j + 1 }   # 1..9, 2x2 tiles -> partial edges
    it  = src.blocks(2, 2)
    SCANS.each do |op|
      exact = op == :cummax || op == :cummin || op == :cumcount
      assert_scan block_ref_2d(src, 2, 2, op), it.send(op), op, exact, "block2d"
    end
  end

  def test_block_scan_masked_float
    src = CArray.float64(8) { |i| i + 1.0 }
    src[2] = UNDEF                                   # interior masks (tiles keep a real first cell)
    src[5] = UNDEF
    it = src.blocks(4)
    SCANS.each do |op|
      exact = op == :cummax || op == :cummin || op == :cumcount
      assert_scan block_ref_1d(src, 4, op), it.send(op), op, exact, "block masked"
    end
  end

  def test_block_scan_dtypes
    it = CArray.int32(6) { |i| i + 1 }.blocks(3)
    assert_equal "float64", it.cumsum.data_type_name
    assert_equal "float64", it.cumprod.data_type_name
    assert_equal "int32",   it.cummax.data_type_name
    assert_equal "int32",   it.cummin.data_type_name
    assert_equal "int64",   it.cumcount.data_type_name
  end

  # ---- (b) CACategoricalIterator ------------------------------------------

  def check_categorical(v, cat, msg, object: false)
    vals, codes, k, masks = flat_cat(v, cat)
    it = v.group_by_category(cat)
    SCANS.each do |op|
      exact = object || op == :cummax || op == :cummin || op == :cumcount
      assert_scan group_scan(vals, codes, k, masks, op), it.send(op), op, exact, msg
    end
  end

  def test_categorical_scan_int_and_float
    v   = CArray.int32(9) { |i| (i * 4 + 1) % 7 }
    cat = (CArray.int32(9) { |i| i % 3 }).categorize
    check_categorical(v, cat, "cat int")
    vf  = CArray.float64(9) { |i| Math.cos(i) + 1 }
    check_categorical(vf, cat, "cat float")
  end

  def test_categorical_scan_masked
    v = CArray.float64(9) { |i| i + 1.0 }
    v[2] = UNDEF
    v[7] = UNDEF
    cat = (CArray.int32(9) { |i| i % 3 }).categorize
    check_categorical(v, cat, "cat masked")
  end

  def test_categorical_scan_excluded
    # fixed vocabulary {0,1}: key 2 is out-of-vocabulary -> excluded cell.
    keys = CArray.int32(9) { |i| i % 3 }
    cat  = keys.categorize(labels: [0, 1])
    v    = CArray.float64(9) { |i| i + 1.0 }
    check_categorical(v, cat, "cat excluded")
  end

  def test_categorical_scan_dtypes
    v   = CArray.int32(6) { |i| i + 1 }
    cat = (CArray.int32(6) { |i| i % 2 }).categorize
    it  = v.group_by_category(cat)
    assert_equal "float64", it.cumsum.data_type_name
    assert_equal "float64", it.cumprod.data_type_name
    assert_equal "int32",   it.cummax.data_type_name
    assert_equal "int32",   it.cummin.data_type_name
    assert_equal "int64",   it.cumcount.data_type_name
  end

  # cumcount is the 1-based running count of present cells per group -- the same
  # convention the slab / block (core) members use, so the whole family agrees.
  def test_categorical_cumcount_is_one_based_count
    v   = CArray.float64(6) { |i| i + 1.0 }
    cat = (CArray.int32(6) { |i| i % 2 }).categorize   # groups {0,2,4} and {1,3,5}
    assert_equal [1, 1, 2, 2, 3, 3], v.group_by_category(cat).cumcount.to_a
  end

  # ---- (b) CAGroupIterator (flat + band, agreement with categorical) -------

  def test_group_scan_flat_matches_categorical
    v   = CArray.float64(9) { |i| i + 1.0 }
    v[4] = UNDEF
    cat = (CArray.int32(9) { |i| i % 3 }).categorize
    vals, codes, k, masks = flat_cat(v, cat)
    git = v[cat]
    SCANS.each do |op|
      assert_scan group_scan(vals, codes, k, masks, op),
                  git.send(op, axis: :group), op,
                  (op == :cummax || op == :cummin || op == :cumcount),
                  "group flat"
      # and it must equal the categorical member on the same flat grouping
      assert_equal v.group_by_category(cat).send(op).to_a,
                   git.send(op, axis: :group).to_a, "group vs categorical (#{op})"
    end
  end

  def test_group_scan_band_preserving
    # group the leading axis, keep the trailing band: each band column is an
    # independent flat categorical scan of that column's grouped cells.
    v   = CArray.float64(6, 2) { |i, j| i * 2 + j + 1.0 }
    cat = (CArray.int32(6) { |i| i % 2 }).categorize
    git = v[cat, nil]
    SCANS.each do |op|
      # reference: run the flat categorical scan per band column.
      n0, n1 = v.shape
      exp = Array.new(n0 * n1)
      (0...n1).each do |j|
        col   = CArray.float64(n0) { |i| v[i, j] }
        vals, codes, k, masks = flat_cat(col, cat)
        colsc = group_scan(vals, codes, k, masks, op)
        (0...n0).each { |i| exp[i * n1 + j] = colsc[i] }
      end
      exact = op == :cummax || op == :cummin || op == :cumcount
      assert_scan exp, git.send(op, axis: :group), op, exact, "group band"
    end
  end

  # ---- (d) object-dtype sanity through CACategoricalIterator ---------------

  def test_object_categorical_scan
    v   = CArray.object(8) { |i| (i * 3 + 1) % 7 }
    cat = (CArray.int32(8) { |i| i % 3 }).categorize
    check_categorical(v, cat, "object Integer", object: true)
    assert_equal "object", v.group_by_category(cat).cumsum.data_type_name
    assert_equal "object", v.group_by_category(cat).cummax.data_type_name
    assert_equal "int64",  v.group_by_category(cat).cumcount.data_type_name

    vb  = CArray.object(6) { |i| BigDecimal([3, 1, 4, 1, 5, 9][i].to_s) }
    cb  = (CArray.int32(6) { |i| i % 2 }).categorize
    check_categorical(vb, cb, "object BigDecimal", object: true)
  end

  # ---- (e) empty-extremum family agreement --------------------------------

  # cummax / cummin have no identity: a fiber's running extremum is undefined
  # until its first present cell.  A leading masked run therefore yields UNDEF
  # (masked) output.  Every iterator member that scans a single fiber must
  # agree with the core CArray scan -- CASlabIterator / CABlockIterator
  # delegate to it, and CACategoricalIterator / CAGroupIterator (which already
  # UNDEF empty extrema) must land on the same answer.
  def test_family_agrees_empty_extremum_is_undef
    base = CArray.float64(6) { |i| [9, 8, 3, 1, 4, 1][i].to_f }
    base[0] = UNDEF
    base[1] = UNDEF                                   # leading masked run

    [:cummax, :cummin].each do |op|
      core = base.send(op)                            # core CArray scan (flat)
      assert_equal [true, true, false, false, false, false], core.is_masked.to_a, "core #{op} leading UNDEF"

      # CASlabIterator: single-row 2-D, slab axis = last -> one fiber == base.
      slab = base.reshape(1, 6)[nil, :>].send(op)
      assert_equal core.to_a,           slab.to_a.flatten,           "slab==core (#{op})"
      assert_equal core.is_masked.to_a, slab.is_masked.to_a.flatten, "slab mask (#{op})"

      # CABlockIterator: one tile spanning the whole array -> one fiber.
      blk = base.blocks(6).send(op)
      assert_equal core.to_a,           blk.to_a.flatten,            "block==core (#{op})"
      assert_equal core.is_masked.to_a, blk.is_masked.to_a.flatten,  "block mask (#{op})"

      # CACategoricalIterator / CAGroupIterator: single group == whole fiber.
      cat  = (CArray.int32(6) { 0 }).categorize
      catm = base.group_by_category(cat).send(op)
      grpm = base[cat].send(op, axis: :group)
      assert_equal core.to_a,           catm.to_a,           "categorical==core (#{op})"
      assert_equal core.is_masked.to_a, catm.is_masked.to_a, "categorical mask (#{op})"
      assert_equal core.to_a,           grpm.to_a,           "group==core (#{op})"
      assert_equal core.is_masked.to_a, grpm.is_masked.to_a, "group mask (#{op})"
    end
  end
end

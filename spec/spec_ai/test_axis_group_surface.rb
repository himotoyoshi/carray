# Test for the axis-group reduction surface (PROPOSAL_AXIS_GROUP Phase 3):
#   CACategorical (classifier), CArray#axis_group / AxisGroup, the [] type gate
#   + CAGroupIterator, :group reduce dispatch, and GroupLabels.
#
# The apply path is C-level (ext/ca_group_iter.c type gate + CAGroupIterator
# + reduce driving over __axis_group_reduce__); AxisGroup / GroupLabels
# metadata is Ruby (lib/carray/axis_group.rb).  The classifier is CACategorical
# (lib/carray/categorical.rb), built via `categorize` / CACategorical.from_codes.
# Exercises autoload wiring too (plain require "carray").

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../ext", __dir__)
require "test/unit"
require "carray"

class TestAxisGroupSurface < Test::Unit::TestCase

  EPS = 1e-12

  # Independent pure-Ruby reference (nested loops, no kernel).  Group-reduces
  # `arr` over `slots` (CACategorical or nil) into a nested Array in slot order;
  # `fused` lists band SLOT positions folded into the statistic.
  def ref(arr, slots, op, fused = [])
    shape = arr.shape
    meta = []
    cur = 0
    slots.each do |s|
      if s.nil?
        meta << { kind: :band, axis: cur, len: shape[cur] }; cur += 1
      else
        r = s.ndim
        meta << { kind: :group, axes: (cur...cur + r).to_a, cat: s }; cur += r
      end
    end
    out_axes = []
    meta.each_with_index do |m, si|
      if m[:kind] == :group
        out_axes << { si: si, len: m[:cat].labels.size, kind: :group }
      elsif !fused.include?(si)
        out_axes << { si: si, len: m[:len], kind: :band }
      end
    end
    buckets = Hash.new { |h, k| h[k] = [] }
    idx = Array.new(arr.ndim, 0)
    arr.elements.times do
      masked = arr.has_mask? && arr.mask[*idx]
      unless masked
        v = arr[*idx]
        coord = []
        skip = false
        out_axes.each do |o|
          m = meta[o[:si]]
          if o[:kind] == :group
            sub = 0
            m[:axes].each { |a| sub = sub * shape[a] + idx[a] }
            c = m[:cat].codes[sub]           # excluded cell -> masked (UNDEF)
            (skip = true; break) if c.equal?(UNDEF) || c < 0 || c >= m[:cat].labels.size
            coord << c
          else
            coord << idx[m[:axis]]
          end
        end
        buckets[coord] << v unless skip
      end
      (arr.ndim - 1).downto(0) do |k|
        idx[k] += 1; break if idx[k] < shape[k]; idx[k] = 0
      end
    end
    reduce = lambda do |vals|
      # ERI: identity-bearing ops return their identity on empty (sum 0, prod 1,
      # count 0, all true, any false); ratios / extrema return nil (masked).
      case op
      when :sum   then vals.sum(0.0)
      when :prod  then vals.inject(1.0) { |a, b| a * b }
      when :count then vals.size
      when :all   then vals.all? { |x| x != 0 }
      when :any   then vals.any? { |x| x != 0 }
      when :mean  then vals.empty? ? nil : vals.sum(0.0) / vals.size
      when :min   then vals.empty? ? nil : vals.min.to_f
      when :max   then vals.empty? ? nil : vals.max.to_f
      when :variance, :stddev
        next nil if vals.empty?
        next 0.0 if vals.size == 1                    # n=1 contract
        m = vals.sum(0.0) / vals.size
        var = vals.sum(0.0) { |x| (x - m)**2 } / (vals.size - 1)
        op == :stddev ? Math.sqrt(var) : var
      end
    end
    out_shape = out_axes.map { |o| o[:len] }
    build = lambda do |dims, prefix|
      dims.empty? ? reduce.call(buckets[prefix]) :
        (0...dims[0]).map { |i| build.call(dims[1..], prefix + [i]) }
    end
    out_shape.empty? ? reduce.call(buckets[[]]) : build.call(out_shape, [])
  end

  def assert_close(exp, act, eps = EPS, msg = nil)
    fe = exp.respond_to?(:flatten) ? exp.flatten : [exp]
    fa = (act.respond_to?(:to_a) ? act.to_a : act)
    fa = fa.respond_to?(:flatten) ? fa.flatten : [fa]
    assert_equal fe.size, fa.size, "size #{msg}"
    fe.zip(fa).each do |x, y|
      y = nil if y.equal?(UNDEF)   # masked cell -> treat as nil (empty group)
      if x.nil? || y.nil?
        assert_equal x, y, "nil mismatch #{msg}"
      else
        assert_in_delta x, y, eps * (1 + x.abs), msg.to_s
      end
    end
  end

  def setup
    @t = CArray.float64(6, 2, 3) { |i, j, k| Math.sin(i) + j * 10 + k }
    @mon = (CArray.int32(6) { |i| [0, 1, 2, 0, 1, 2][i] }).categorize
    @lonb = (CArray.int32(2) { |j| j }).categorize
  end

  # ---- autoload + constants ------------------------------------------------

  def test_autoload_via_plain_require
    cat = (CArray.int32(3) { |i| i }).categorize
    assert_kind_of CACategorical, cat
    g = @t.axis_group(@mon, nil, nil)
    assert_kind_of AxisGroup, g
    assert_kind_of CAGroupIterator, @t[@mon, nil, nil]
    assert_operator CAGroupIterator, :<, CAIterator
  end

  # ---- categorical classifier ----------------------------------------------

  def test_categorical_appearance_order
    cat = (CArray.object(4) { |i| %w[b a a c][i] }).categorize
    assert_equal %w[b a c], cat.labels
    assert_equal [0, 1, 1, 2], cat.codes.to_a
    assert_equal 3, cat.labels.size
    assert_equal 1, cat.ndim
  end

  def test_categorical_fixed_vocabulary_order
    cat = (CArray.object(4) { |i| %w[b a a c][i] }).categorize(labels: %w[a b c])
    assert_equal %w[a b c], cat.labels
    assert_equal [1, 0, 0, 2], cat.codes.to_a
  end

  def test_categorical_out_of_vocabulary_excluded
    # a value absent from a fixed vocabulary is excluded (masked code = skipped)
    cat = (CArray.object(3) { |i| %w[a z b][i] }).categorize(labels: %w[a b])
    assert_equal [0, nil, 1], cat.codes.to_a.map { |c| c.equal?(UNDEF) ? nil : c }
    a = CArray.float64(3) { |i| i + 1.0 }   # [1,2,3]
    r = a[cat].sum(axis: :group)             # group a=>{1}, b=>{3}; z skipped
    assert_close [1.0, 3.0], r
  end

  def test_categorical_rank_n
    region = CArray.int32(2, 3) { |j, k| [[0, 0, 1], [1, 2, 2]][j][k] }
    cat = region.categorize
    assert_equal 2, cat.ndim
    assert_equal [2, 3], cat.shape
    assert_equal 3, cat.labels.size
  end

  # ---- apply + reductions vs independent reference -------------------------

  def test_single_group_axis_all_ops
    [:sum, :prod, :mean, :min, :max, :variance, :stddev, :count].each do |op|
      r = @t[@mon, nil, nil].public_send(op, axis: :group)
      assert_equal [3, 2, 3], r.shape, "#{op} shape"
      assert_close ref(@t, [@mon, nil, nil], op), r, EPS, op
    end
  end

  def test_boolean_reductions
    tb = CArray.float64(6, 2, 3) { |i, j, k| (i + j + k).even? ? 0.0 : 1.0 }
    [:all, :any].each do |op|
      r = tb[@mon, nil, nil].public_send(op, axis: :group)
      rb = r.to_a.flatten
      rf = ref(tb, [@mon, nil, nil], op).flatten.map { |x| x.nil? ? nil : !!x }
      assert_equal rf, rb, op.to_s
    end
  end

  def test_multi_group_axis
    g = [@mon, @lonb, nil]
    [:sum, :mean, :min, :max, :variance].each do |op|
      r = @t[*g].public_send(op, axis: :group)
      assert_equal [3, 2, 3], r.shape
      assert_close ref(@t, g, op), r, EPS, op
    end
  end

  def test_rank_n_nonrectangular_band_preserved
    region = CArray.int32(2, 3) { |j, k| [[0, 0, 1], [1, 2, 2]][j][k] }
    pref = region.categorize
    g = [nil, pref]   # band axis 0 preserved, axes 1+2 -> 1 region axis
    [:sum, :mean, :count].each do |op|
      r = @t[*g].public_send(op, axis: :group)
      assert_equal [6, 3], r.shape   # [nt, n_region]
      assert_close ref(@t, g, op), r, EPS, op
    end
  end

  def test_band_axis_ordering_group_at_end
    # band, band, group  ->  output [band0, band1, group]  (slot order, group
    # axis stays at its slot position, not pulled to the front)
    s = CArray.float64(2, 3, 6) { |i, j, k| i + j + Math.cos(k) }
    rr = s[nil, nil, @mon].mean(axis: :group)
    assert_equal [2, 3, 3], rr.shape
    assert_close ref(s, [nil, nil, @mon], :mean), rr
  end

  def test_mask
    tm = CArray.float64(6, 2, 3) { |i, j, k| i + j + k }
    tm[1, 0, 0] = UNDEF
    tm[4, 1, 2] = UNDEF
    [:sum, :mean, :count, :min, :variance].each do |op|
      r = tm[@mon, nil, nil].public_send(op, axis: :group)
      assert_close ref(tm, [@mon, nil, nil], op), r, EPS, op
    end
  end

  def test_native_dtypes
    tf = CArray.float32(6, 2, 3) { |i, j, k| i * 1.5 + j + k }
    assert_close ref(tf, [@mon, nil, nil], :mean),
                 tf[@mon, nil, nil].mean(axis: :group), 1e-5
    ti = CArray.int32(6, 2, 3) { |i, j, k| i * 100 + j * 10 + k }
    assert_close ref(ti, [@mon, nil, nil], :sum),
                 ti[@mon, nil, nil].sum(axis: :group)
  end

  def test_empty_group_is_undef
    # a fixed vocabulary with an unused middle label gives an empty group
    cat = (CArray.object(4) { |i| %w[a a c c][i] }).categorize(labels: %w[a b c])
    a = CArray.float64(4) { |i| i + 1.0 }
    r = a[cat].mean(axis: :group)
    assert_equal 3, r.shape[0]
    assert r.mask[1], "empty group b is UNDEF"
    assert !r.mask[0] && !r.mask[2]
    cnt = a[cat].count(axis: :group)
    assert_equal [2, 0, 2], cnt.to_a   # count is 0 (not UNDEF) for empty group
  end

  # ---- one-shot vs pre-built spec ------------------------------------------

  def test_oneshot_and_prebuilt_equivalent
    g = @t.axis_group(@mon, nil, nil)
    a = @t[@mon, nil, nil].mean(axis: :group)
    b = @t[g].mean(axis: :group)
    assert_equal a.to_a, b.to_a
  end

  def test_spec_reuse_across_arrays
    g = @t.axis_group(@mon, nil, nil)
    other = CArray.float64(6, 2, 3) { |i, j, k| i * 7 + j - k }
    assert_close ref(other, [@mon, nil, nil], :sum),
                 other[g].sum(axis: :group)
  end

  # ---- type gate (no regression) -------------------------------------------

  def test_type_gate_plain_index_unaffected
    sel = CArray.int32(3) { |i| [0, 2, 4][i] }
    plain = @t[sel, nil, nil]
    assert_not_kind_of CAGroupIterator, plain
    assert_equal [3, 2, 3], plain.shape
    assert_equal @t[0, nil, nil].to_a, plain[0, nil, nil].to_a
  end

  def test_type_gate_scalar_and_range_unaffected
    assert_in_delta @t[2, 1, 2], @t.to_a[2][1][2], 0
    assert_equal [2, 2, 3], @t[1..2, nil, nil].shape
  end

  # ---- dispatch: :group required, delegation --------------------------------

  def test_axis_int_delegates_plain
    r = @t[@mon, nil, nil].mean(axis: 1)
    assert_equal @t.mean(axis: 1).to_a, r.to_a
  end

  def test_no_axis_delegates_plain
    assert_in_delta @t.sum, @t[@mon, nil, nil].sum, EPS
    assert_in_delta @t.mean, @t[@mon, nil, nil].mean, EPS
  end

  def test_group_not_engaged_without_group_symbol
    # axis: integer must NOT engage grouping
    r = @t[@mon, nil, nil].sum(axis: 0)
    assert_equal @t.sum(axis: 0).to_a, r.to_a
    assert_not_equal [3, 2, 3], r.shape
  end

  # ---- fused band axis (axis: [:group, k]) ---------------------------------

  def test_fused_band_axis
    g = [@mon, @lonb, nil]   # [3, 2, nlat]; fold band slot 2
    r = @t[*g].mean(axis: [:group, 2])
    assert_equal [3, 2], r.shape
    assert_close ref(@t, g, :mean, [2]), r
    rs = @t[*g].sum(axis: [:group, 2])
    assert_close ref(@t, g, :sum, [2]), rs
  end

  def test_fused_band_rejects_group_slot_integer
    g = @t.axis_group(@mon, @lonb, nil)
    assert_raise(IndexError) { @t[g].mean(axis: [:group, 0]) }  # slot 0 is group
  end

  # ---- labels --------------------------------------------------------------

  def test_labels_tuple_alignment
    g = @t.axis_group(@mon, @lonb, nil)
    r = @t[g].mean(axis: :group)
    assert_equal r.shape.to_a, g.labels.shape
    assert_equal [@mon.labels[0], @lonb.labels[1], 2], g.labels(0, 1, 2)
    # band axis label = its index
    assert_equal [@mon.labels[2], @lonb.labels[0], 1], g.labels(2, 0, 1)
  end

  def test_labels_lockstep_with_reduction
    g = @t.axis_group(@mon, @lonb, nil)
    rv = @t[g].mean(axis: [:group, 2])   # [3, 2]
    lab = g.labels(axis: [:group, 2])
    assert_kind_of GroupLabels, lab
    assert_equal rv.shape.to_a, lab.shape
    assert_equal [@mon.labels[1], @lonb.labels[0]], lab[1, 0]
  end

  def test_labels_axis_requires_group
    g = @t.axis_group(@mon, nil, nil)
    assert_raise(ArgumentError) { g.labels(axis: 1) }
  end

  def test_group_labels_axis_vectors
    g = @t.axis_group(@mon, @lonb, nil)
    lab = g.labels
    assert_equal @mon.labels, lab.axis(0)
    assert_equal @lonb.labels, lab.axis(1)
    assert_equal (0...3).to_a, lab.axis(2)   # band identity (axis 2 length 3)
    assert_equal [@mon.labels, @lonb.labels, [0, 1, 2]], lab.coords
  end

  # ---- spec validation errors ----------------------------------------------

  def test_trailing_omission_forbidden
    # all axes must be explicit (no implicit nil fill)
    assert_raise(IndexError) { @t.axis_group(@mon) }       # 1 of 3 axes
    assert_raise(IndexError) { @t.axis_group(@mon, nil) }  # 2 of 3 axes
  end

  def test_categorical_shape_mismatch
    bad = (CArray.int32(5) { |i| i % 2 }).categorize  # len 5 != 6
    assert_raise(IndexError) { @t.axis_group(bad, nil, nil) }
  end

  def test_bad_slot_type
    assert_raise(TypeError) { @t.axis_group(@mon, 1, nil) }
  end

  # ---- CAGroupIterator is not an array -------------------------------------

  def test_iterator_is_not_an_array
    it = @t[@mon, nil, nil]
    assert_not_respond_to it, :to_ca
    assert_kind_of CArray, it.value
    assert_kind_of AxisGroup, it.spec
  end

  # ---- Phase 4 conform: count family + tier-2 (vs the categorical sibling) ----

  def test_group_conform_count_family_and_tier2
    keys = %w[b a b c a b]
    cat  = CA_OBJECT(keys).categorize                # labels [b,a,c]
    val  = CA_DOUBLE([10, 20, 30, 40, 50, 60])
    g    = val[cat]
    ref  = val.group_by_category(cat)                # the reference sibling
    assert_equal ref.count_not_masked.to_a, g.count_not_masked(axis: :group).to_a
    assert_equal ref.elements.to_a,          g.elements(axis: :group).to_a
    assert_equal ref.count_masked.to_a,      g.count_masked(axis: :group).to_a
    assert_close ref.variancep.to_a,         g.variancep(axis: :group)   # pop, n=1 -> 0.0
    assert_close ref.stddevp.to_a,           g.stddevp(axis: :group)
    mn, mx = g.minmax(axis: :group)
    assert_equal ref.min.to_a, mn.to_a
    assert_equal ref.max.to_a, mx.to_a
  end

  def test_group_conform_masked_value_count_split
    cat = CA_OBJECT(%w[b a b c a b]).categorize
    val = CA_DOUBLE([10, 20, 30, 40, 50, 60]); val[2] = UNDEF   # 'b' loses one value
    g   = val[cat]
    assert_equal [2, 2, 1], g.count_not_masked(axis: :group).to_a
    assert_equal [3, 2, 1], g.elements(axis: :group).to_a        # classified, mask-independent
    assert_equal [1, 0, 0], g.count_masked(axis: :group).to_a
  end

  # UNDEF-aware element-wise comparison of two group results.
  def assert_group_match(exp_ca, act_ca, msg = nil)
    e = exp_ca.to_a.flatten
    a = act_ca.to_a.flatten
    assert_equal e.size, a.size, "size #{msg}"
    e.zip(a).each do |x, y|
      x = nil if x.equal?(UNDEF)
      y = nil if y.equal?(UNDEF)
      if x.nil? || y.nil?
        assert_equal x, y, "#{msg}"
      else
        assert_in_delta x, y, 1e-9 * (1 + x.abs), "#{msg}"
      end
    end
  end

  def test_group_conform_weighted
    cat = CA_OBJECT(%w[b a b c a b]).categorize
    val = CA_DOUBLE([10, 20, 30, 40, 50, 60])
    wts = CA_DOUBLE([1, 1, 2, 1, 3, 1])
    g   = val[cat]; ref = val.group_by_category(cat)
    assert_group_match ref.wsum(wts),  g.wsum(wts, axis: :group)
    assert_group_match ref.wmean(wts), g.wmean(wts, axis: :group)
    # weighted with an empty group + a value-masked cell: matches categorical
    c2 = CA_OBJECT(%w[a a b]).categorize(labels: %w[a b c])   # 'c' empty
    v2 = CA_DOUBLE([10, 20, 30]); v2[0] = UNDEF
    w2 = CA_DOUBLE([2, 3, 1])
    assert_group_match v2.group_by_category(c2).wmean(w2), v2[c2].wmean(w2, axis: :group)
  end

  def test_group_conform_min_max_addr
    # single group axis: flat source address matches the categorical sibling
    cat = CA_OBJECT(%w[b a b c a b]).categorize
    val = CA_DOUBLE([10, 20, 30, 40, 50, 60])
    g   = val[cat]; ref = val.group_by_category(cat)
    assert_equal ref.min_addr.to_a, g.min_addr(axis: :group).to_a
    assert_equal ref.max_addr.to_a, g.max_addr(axis: :group).to_a
    assert_equal g.min(axis: :group).to_a, val.reshape(6)[g.min_addr(axis: :group)].to_a
    # 2-D with a preserved band axis + multiple cells per (group, band): the flat
    # address must index back into the raveled source (band-order reconstruction).
    v   = CA_DOUBLE([[10, 2], [3, 40], [50, 6], [7, 80]])   # shape [4, 2]
    lat = CA_INT32([0, 1, 0, 1]).categorize                 # group axis0 -> rows {0,2},{1,3}
    g2  = v[lat, nil]                                        # band = axis1
    ma  = g2.min_addr(axis: :group)
    assert_equal [2, 2], ma.shape
    assert_equal g2.min(axis: :group).to_a, v.reshape(8)[ma].to_a
    assert_equal g2.max(axis: :group).to_a, v.reshape(8)[g2.max_addr(axis: :group)].to_a
    # empty group -> masked
    g3 = CA_DOUBLE([10, 20, 30])[CA_OBJECT(%w[a a b]).categorize(labels: %w[a b c])]
    assert_equal true, g3.min_addr(axis: :group).is_masked[2]
  end

  def test_group_conform_flat_order_and_iterate
    cat = CA_OBJECT(%w[b a b c a b]).categorize
    val = CA_DOUBLE([10, 20, 30, 40, 50, 60])
    g   = val[cat]; ref = val.group_by_category(cat)
    # order statistics + sort_addr match the categorical sibling (flat grouping)
    assert_equal ref.median.to_a,          g.median(axis: :group).to_a
    assert_equal ref.percentile(25).to_a,  g.percentile(25, axis: :group).to_a
    assert_equal ref.quantile.map(&:to_a), g.quantile(axis: :group).map(&:to_a)
    assert_equal ref.sort_addr.to_a,       g.sort_addr(axis: :group).to_a
    # generic iterate
    seen = []; g.each { |m| seen << m.to_a }
    assert_equal [[10.0, 30.0, 60.0], [20.0, 50.0], [40.0]], seen
    assert_equal ref.reduce { |m| m.max - m.min }.to_a, g.reduce { |m| m.max - m.min }.to_a
    # no :group -> plain value reduction
    assert_equal val.median, g.median
  end

  # ---- band-preserving order statistics (per-band-fiber materialize) --------

  # Independent per-(group, band) order-statistic reference for a rank-1 single
  # group axis + band axes. Groups the members along `ga` per band position and
  # takes the linear percentile; empty groups stay nil (masked).
  def band_order_ref(arr, codes, k, ga, p)
    ndim = arr.ndim; shape = arr.shape
    out_shape = shape.dup; out_shape[ga] = k
    band = (0...ndim).reject { |a| a == ga }
    blens = band.map { |a| shape[a] }
    result = CArray.float64(*out_shape); result[] = UNDEF
    blens.inject(1, :*).times do |t|
      idx = Array.new(ndim); rem = t
      band.each_index.to_a.reverse_each { |j| idx[band[j]] = rem % blens[j]; rem /= blens[j] }
      (0...k).each do |gidx|
        mem = []
        (0...shape[ga]).each do |m|
          next unless codes[m] == gidx
          gi = idx.dup; gi[ga] = m
          next if arr.has_mask? && arr.mask[*gi]
          mem << arr[*gi]
        end
        next if mem.empty?
        oi = idx.dup; oi[ga] = gidx
        s = mem.sort; n = s.size
        rank = (p / 100.0) * (n - 1); lo = rank.floor; hi = rank.ceil
        result[*oi] = s[lo] + (s[hi] - s[lo]) * (rank - lo)
      end
    end
    # Flat list with nil for empty (masked) cells, aligned to a row-major
    # flatten of the actual result (assert_close compares them flattened).
    result.to_a.flatten.map { |x| x.equal?(UNDEF) ? nil : x }
  end

  def test_band_order_stats_cat_on_axis0
    val   = CArray.float64(6, 4) { |i, j| Math.sin(i * 3 + j) }
    codes = [0, 1, 0, 2, 1, 0]
    cat   = CA_INT32(codes).categorize(labels: [0, 1, 2])
    g     = val[cat, nil]   # group axis 0 (k=3), band axis 1
    # output shape matches the scatter reductions
    assert_equal g.mean(axis: :group).shape, g.median(axis: :group).shape
    assert_equal [3, 4], g.median(axis: :group).shape
    assert_close band_order_ref(val, codes, 3, 0, 50), g.median(axis: :group)
    assert_close band_order_ref(val, codes, 3, 0, 25), g.percentile(25, axis: :group)
    q = g.quantile(axis: :group)
    assert_equal 5, q.size
    q.each { |c| assert_equal [3, 4], c.shape }
    [0, 25, 50, 75, 100].each_with_index do |p, i|
      assert_close band_order_ref(val, codes, 3, 0, p), q[i]
    end
  end

  def test_band_order_stats_cat_on_axis1
    val   = CArray.float64(6, 4) { |i, j| Math.cos(i + j * 2) }
    codes = [0, 1, 0, 2]
    cat   = CA_INT32(codes).categorize(labels: [0, 1, 2])
    g     = val[nil, cat]   # band axis 0, group axis 1 (k=3)
    assert_equal g.mean(axis: :group).shape, g.median(axis: :group).shape
    assert_equal [6, 3], g.median(axis: :group).shape
    assert_close band_order_ref(val, codes, 3, 1, 50), g.median(axis: :group)
    assert_close band_order_ref(val, codes, 3, 1, 75), g.percentile(75, axis: :group)
  end

  # ---- band-preserving generic iterate + sort_addr (per-band-fiber) ----------

  def test_band_reduce
    val   = CArray.float64(6, 4) { |i, j| (i * 4 + j).to_f }
    codes = [0, 1, 0, 2, 1, 0]
    cat   = CA_INT32(codes).categorize(labels: [0, 1, 2])
    g     = val[cat, nil]                       # group axis 0 (k=3), band axis 1
    out   = g.reduce { |m| m.max - m.min }
    assert_equal [3, 4], out.shape
    # independent reference: per (group, band) max-min over the members along ga
    (0...3).each do |gidx|
      rows = (0...6).select { |m| codes[m] == gidx }
      (0...4).each do |b|
        mem = rows.map { |m| val[m, b] }
        assert_in_delta (mem.max - mem.min), out[gidx, b], 1e-9
      end
    end
  end

  def test_band_reduce_object_dtype_default
    val   = CArray.float64(4, 2).seq!(1, 1)
    cat   = CA_INT32([0, 1, 0, 1]).categorize(labels: [0, 1])
    g     = val[cat, nil]
    out   = g.reduce { |m| m.to_a }             # arbitrary object per (group, band)
    assert_equal CA_OBJECT, out.data_type
    assert_equal [2, 2], out.shape
  end

  def test_band_map
    val   = CArray.float64(4, 3).seq!(10, 1)
    cat   = CA_INT32([0, 1, 0, 1]).categorize(labels: [0, 1])
    g     = val[cat, nil]                       # group axis 0 (k=2), band axis 1
    out   = g.map { |m| m - m.mean }            # centre within each (group, band)
    assert_equal val.shape, out.shape
    # position 0,2 are group 0; 1,3 are group 1; each band centred separately
    (0...3).each do |b|
      g0 = [val[0, b], val[2, b]]
      g1 = [val[1, b], val[3, b]]
      assert_in_delta val[0, b] - (g0.sum / 2.0), out[0, b], 1e-9
      assert_in_delta val[2, b] - (g0.sum / 2.0), out[2, b], 1e-9
      assert_in_delta val[1, b] - (g1.sum / 2.0), out[1, b], 1e-9
      assert_in_delta val[3, b] - (g1.sum / 2.0), out[3, b], 1e-9
    end
  end

  def test_band_map_excluded_cell_is_undef
    val = CArray.float64(3, 2).seq!(1, 1)
    # code 1 excluded (masked): only labels [0] valid, cell at ga-position 1 drops
    cat = CA_INT32([0, 1, 0]).categorize(labels: [0])   # position 1 has out-of-vocab code
    g   = val[cat, nil]
    out = g.map { |m| m * 0 + 7 }
    assert_equal val.shape, out.shape
    (0...2).each do |b|
      assert_equal 7.0, out[0, b]
      assert_equal 7.0, out[2, b]
      assert_equal true, out.is_masked[1, b]                # excluded cell -> UNDEF
    end
  end

  def test_band_each
    val   = CArray.float64(4, 3).seq!(0, 1)
    cat   = CA_INT32([0, 1, 0, 1]).categorize(labels: [0, 1])
    g     = val[cat, nil]                       # k=2, band len 3
    seen = []
    ret = g.each { |m| seen << m.to_a }
    assert_same g, ret
    assert_equal 6, seen.size                   # band(3) * k(2)
    # band-major then category: band0 grp0, band0 grp1, band1 grp0, ...
    assert_equal [val[0, 0], val[2, 0]], seen[0]
    assert_equal [val[1, 0], val[3, 0]], seen[1]
    assert_equal [val[0, 1], val[2, 1]], seen[2]
    # no block -> Enumerator yielding the same members
    assert_kind_of Enumerator, g.each
    assert_equal seen, g.each.to_a.map(&:to_a)
  end

  def test_band_sort_addr
    val   = CArray.float64(4, 3).seq!(10, 1)    # row-major flat addr order
    codes = [0, 1, 0, 1]
    cat   = CA_INT32(codes).categorize(labels: [0, 1])
    g     = val[cat, nil]                       # group axis 0, band axis 1
    sa    = g.sort_addr(axis: :group)
    nvalid = cat.category_sizes.int64.sum             # 4 classified cells per fiber
    assert_equal 3 * nvalid, sa.elements        # regular: nfiber * nvalid
    vflat = val.reshape(val.elements)
    # each fiber's block (length nvalid) indexes back to that fiber's grouped,
    # ascending-within-group values
    (0...3).each do |b|
      block = sa[b * nvalid ... (b + 1) * nvalid]
      # reference: fiber-local grouped-sorted flat addresses, lifted to full addr
      ref = val[nil, b].group_by_category(cat).sort_addr    # into fiber
      # map to full: full addr of fiber-position p at band b = p*3 + b
      full = ref.to_a.map { |p| p * 3 + b }
      assert_equal full, block.to_a
      # round-trip: values match the fiber grouped-sorted order
      fiber_ref = val[nil, b].reshape(4)[ref].to_a
      assert_equal fiber_ref, vflat[block].to_a
    end
  end

  def test_band_sort_addr_masked_value_to_tail
    val = CArray.float64(4, 2).seq!(1, 1)
    val[2, 0] = UNDEF                           # a masked value in group 0, band 0
    codes = [0, 1, 0, 1]
    cat   = CA_INT32(codes).categorize(labels: [0, 1])
    g     = val[cat, nil]
    sa    = g.sort_addr(axis: :group)
    nvalid = cat.category_sizes.int64.sum
    # band 0, group 0 occupies the first bincount[0]=2 slots; the masked cell
    # (source position 2, band 0 -> flat addr 2*2+0 = 4) sorts to the tail of it
    block0 = sa[0 ... nvalid]
    assert_equal 4, block0.to_a[1]              # masked cell last within group 0
  end

  # ---- composite grouping: multiple group slots / rank-N + band -------------
  #
  # The materialize path routes every grouping through one composite categorical
  # over the group block, so multi-group-slot and rank-N-with-band groupings work
  # (the scatter reductions already did; these fill in the order statistics /
  # iterate / sort_addr). Each result matches an independent per-group reference.

  def med_of(mem)
    return nil if mem.empty?
    s = mem.sort; n = s.size
    n.odd? ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2.0
  end

  def test_flat_multi_group
    val  = CArray.float64(6, 4) { |i, j| (i * 4 + j).to_f }
    cat  = CA_INT32([0, 1, 0, 2, 1, 0]).categorize(labels: [0, 1, 2])
    cat2 = CA_INT32([0, 1, 0, 1]).categorize(labels: [0, 1])
    g = val[cat, cat2]                          # group axes 0 (k=3) and 1 (k=2)
    med = g.median(axis: :group)
    assert_equal [3, 2], med.shape              # slot order
    ref = CArray.float64(3, 2); ref[] = UNDEF
    (0...3).each { |a| (0...2).each { |b|
      m = []; (0...6).each { |i| (0...4).each { |j| m << val[i, j] if cat.codes[i] == a && cat2.codes[j] == b } }
      ref[a, b] = med_of(m) unless m.empty? } }
    assert_equal ref.to_a, med.to_a
    assert_equal [3, 2], g.reduce { |m| m.max }.shape      # slot-shaped
    seen = 0; g.each { |m| seen += 1 }; assert_equal 6, seen   # 3*2 composite groups
    sa = g.sort_addr(axis: :group)              # round-trips into the raveled source
    assert_equal g.elements(axis: :group).to_a.flatten.sum, sa.elements
  end

  def test_band_multi_group
    n0, nb, n2 = 4, 3, 4
    v  = CArray.float64(n0, nb, n2) { |i, b, k| (i * 100 + b * 10 + k).to_f }
    c0 = CA_INT32([0, 1, 0, 1]).categorize(labels: [0, 1])       # axis0, k=2
    c2 = CA_INT32([0, 0, 1, 1]).categorize(labels: [0, 1])       # axis2, k=2
    g  = v[c0, nil, c2]                          # groups 0,2 interleaved with band 1
    med = g.median(axis: :group)
    assert_equal [2, nb, 2], med.shape          # slot order, band in the middle
    ref = CArray.float64(2, nb, 2); ref[] = UNDEF
    (0...nb).each { |b| (0...2).each { |a| (0...2).each { |c|
      m = []; (0...n0).each { |i| (0...n2).each { |k| m << v[i, b, k] if c0.codes[i] == a && c2.codes[k] == c } }
      ref[a, b, c] = med_of(m) unless m.empty? } } }
    assert_equal ref.to_a, med.to_a
    assert_equal g.mean(axis: :group).shape, med.shape          # scatter sibling agrees
    assert_equal v.shape, g.map { |m| m * 0 }.shape             # map -> source shape
    assert_equal [2, nb, 2], g.reduce { |m| m.size }.shape      # reduce -> slot shape
    ccat = CACategorical.from_codes((c0.codes.reshape(n0, 1) * 2 + c2.codes.reshape(1, n2)).reshape(n0 * n2),
                                    CA_OBJECT((0...4).to_a))
    nv = ccat.category_sizes.int64.sum
    sa = g.sort_addr(axis: :group)
    assert_equal nb * nv, sa.elements           # regular nband * nvalid
    vf = v.reshape(v.elements)
    (0...nb).each do |b|
      loc = v[nil, b, nil].group_by_category(ccat).sort_addr
      assert_equal v[nil, b, nil].reshape(n0 * n2)[loc].to_a, vf[sa[b * nv...(b + 1) * nv]].to_a
    end
  end

  def test_rank_n_categorical_with_band
    region = CArray.int32(6, 4) { |j, k| (j + k) % 3 }.categorize   # rank-2, k=3
    v = CArray.float64(2, 6, 4) { |i, j, k| (i + j * 2 + k * 3).to_f }
    g = v[nil, region]                          # band axis 0, region axes 1,2 -> 1 group
    med = g.median(axis: :group)
    assert_equal [2, 3], med.shape              # [band, region]
    ref = CArray.float64(2, 3); ref[] = UNDEF
    (0...2).each { |i| (0...3).each { |a|
      m = []; (0...6).each { |j| (0...4).each { |k| m << v[i, j, k] if region.codes[j, k] == a } }
      ref[i, a] = med_of(m) unless m.empty? } }
    assert_equal ref.to_a, med.to_a
    assert_equal g.mean(axis: :group).shape, med.shape          # scatter sibling agrees
  end

  def test_composite_exclusion
    # a cell excluded (out-of-vocab code) in one slot drops from every group
    val  = CArray.float64(6, 4) { |i, j| (i * 4 + j).to_f }
    cat  = CA_INT32([0, 1, 0, 9, 1, 0]).categorize(labels: [0, 1])   # code 9 (row 3) excluded
    cat2 = CA_INT32([0, 1, 0, 1]).categorize(labels: [0, 1])
    g = val[cat, cat2]
    s = g.sum(axis: :group)                     # scatter sibling, ERI identity 0
    ref = CArray.float64(2, 2); ref[] = 0.0
    (0...6).each { |i| next if i == 3; (0...4).each { |j| ref[cat.codes[i], cat2.codes[j]] += val[i, j] } }
    assert_equal ref.to_a, s.to_a
    assert_equal [2, 2], g.median(axis: :group).shape           # excludes row 3 too
  end

  def test_band_order_stats_masked_and_empty
    val   = CArray.float64(6, 4) { |i, j| i * 4.0 + j }
    val[1, 0] = UNDEF; val[3, 2] = UNDEF   # value-masked cells
    codes = [0, 1, 0, 1, 1, 0]             # label 2 unused -> empty group
    cat   = CA_INT32(codes).categorize(labels: [0, 1, 2])
    g     = val[cat, nil]
    r     = g.median(axis: :group)
    assert_equal [3, 4], r.shape
    assert_close band_order_ref(val, codes, 3, 0, 50), r
    (0...4).each { |j| assert_equal true, r.mask[2, j], "empty group row masked" }
  end

  def test_band_order_stats_3d
    val   = CArray.float64(2, 6, 3) { |i, j, k| Math.sin(i + j) + k }
    codes = [0, 1, 0, 2, 1, 0]
    cat   = CA_INT32(codes).categorize(labels: [0, 1, 2])
    g     = val[nil, cat, nil]   # bands 0 and 2, group axis 1 (k=3)
    assert_equal [2, 3, 3], g.median(axis: :group).shape
    assert_equal g.mean(axis: :group).shape, g.median(axis: :group).shape
    assert_close band_order_ref(val, codes, 3, 1, 50), g.median(axis: :group)
  end

  # ---- the one still-unsupported order-stat shape raises honestly ----------

  def test_fold_band_into_order_stat_raises
    cat = CA_INT32([0, 1, 0, 2, 1, 0]).categorize(labels: [0, 1, 2])
    # folding a band INTO an order statistic (axis: [:group, k]) gathers a band
    # axis and a group axis into one statistic -- a different operation.
    v3 = CArray.float64(6, 4, 3) { |i, j, k| i + j + k }
    assert_raise(NotImplementedError) { v3[cat, nil, nil].median(axis: [:group, 1]) }
  end

  # ---- peak sanity: a large band runs without an O(n) grouped copy ---------

  def test_band_order_stats_large_band_completes
    # 50 (group axis) x 20000 (band): 20000 length-50 fibers, one held at a time.
    val = CArray.float64(50, 20000) { |i, j| (i * 2654435761 + j) % 97 }
    cat = (CArray.int32(50) { |i| i % 5 }).categorize
    r   = val[cat, nil].median(axis: :group)
    assert_equal [5, 20000], r.shape
  end

  # ERI: axis-group now matches the categorical sibling on empty / singleton
  # groups (identity for sum/prod/count/all/any, UNDEF for ratios, variance
  # n=1 -> 0.0). Previously axis-group masked empty groups and variance n<2.
  def test_group_conform_eri_matches_categorical
    cat = CA_OBJECT(%w[a a b]).categorize(labels: %w[a b c])  # 'c' empty, 'b' singleton
    val = CA_DOUBLE([10, 20, 30])
    g   = val[cat]; ref = val.group_by_category(cat)
    %i[sum prod count mean min max variance stddev variancep stddevp].each do |op|
      assert_group_match ref.send(op), g.send(op, axis: :group), op
      assert_equal ref.send(op).is_masked.to_a,
                   g.send(op, axis: :group).is_masked.to_a, "#{op} mask"
    end
  end
end

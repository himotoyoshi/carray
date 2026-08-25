# PROPOSAL_CAFACE_PHASE_2 F.2.11 — comprehensive test matrix

require 'test/unit'
require 'carray'

class TestCAFacePhase2 < Test::Unit::TestCase

  # ---- F.2.2 / F.2.3: 構造 + obj_type registration ----

  def test_cadatetime_class_hierarchy
    raw = CArray.int64(5)
    dt = CATime.wrap(raw, unit: :ns)
    assert_kind_of CATime, dt
    assert_kind_of CAView, dt
    assert_kind_of CArray, dt
  end

  def test_catimedelta_class_hierarchy
    raw = CArray.int64(5)
    td = CATimedelta.wrap(raw, unit: :s)
    assert_kind_of CATimedelta, td
    assert_kind_of CAView, td
  end

  def test_face_flag_set
    raw = CArray.int64(5)
    assert_equal true, raw.time(unit: :s).face?
    assert_equal true, raw.timedelta(unit: :s).face?
    assert_equal false, raw.face?
  end

  def test_storage_type_is_int64
    # Y-pilot: Face は surface != storage の 2 軸を持つ。
    # surface (data_type) = CA_FIXLEN (= numeric op を gate するため)
    # storage (parent.data_type) = CA_INT64 (= 実際の格納型、escape hatch)
    dt = CArray.int64(5).time(unit: :ns)
    assert_equal CA_FIXLEN, dt.data_type, "surface = FIXLEN (= mkkernel gate)"
    assert_equal CA_INT64,  dt.parent.data_type, "storage = INT64 (invariant)"
    assert_equal 8, dt.bytes
  end

  def test_wrap_rejects_non_int64
    raw = CArray.float64(5)
    assert_raise(TypeError) { CATime.wrap(raw, unit: :ns) }
    assert_raise(TypeError) { CATimedelta.wrap(raw, unit: :ns) }
  end

  # ---- F.2.4: 構築 API ----

  def test_new_constructor
    dt = CATime.new(10, unit: :ns)
    assert_kind_of CATime, dt
    assert_equal :ns, dt.unit.base
    assert_equal 10, dt.elements
    assert_equal [0]*10, dt.parent.to_a
  end

  def test_new_multidim
    dt = CATime.new(3, 4, unit: :D)
    assert_equal [3, 4], dt.dim
    assert_equal :D, dt.unit.base
  end

  def test_carray_instance_datetime_sugar
    raw = CArray.int64(5) {|i| i * 100}
    dt = raw.time(unit: :ms)
    assert_kind_of CATime, dt
    assert_equal :ms, dt.unit.base
    assert_equal [0, 100, 200, 300, 400], dt.parent.to_a
  end

  def test_carray_instance_timedelta_sugar
    raw = CArray.int64(3) {|i| (i+1) * 60}
    td = raw.timedelta(unit: :s)
    assert_kind_of CATimedelta, td
    assert_equal [60, 120, 180], td.parent.to_a
  end

  def test_unit_symbol_round_trip
    [:Y, :M, :W, :D, :h, :m, :s, :ms, :us, :ns, :ps, :fs, :as].each do |u|
      dt = CArray.int64(3).time(unit: u)
      assert_equal u, dt.unit.base, "unit symbol must round-trip"
    end
  end

  # ---- F.2.5: lift hook auto-activation (Phase 1 deploy 済) ----

  def test_lift_auto_activates_on_range_aref
    dt = CArray.int64(10) {|i| i*100}.time(unit: :s)
    sliced = dt[2..5]
    assert_kind_of CATime, sliced, "lift hook must auto-wrap range result"
    assert_equal :s, sliced.unit.base, "tail unit must carry"
    assert_equal 4, sliced.elements
  end

  def test_lift_parent_pin
    dt = CArray.int64(10) {|i| i}.time(unit: :ns)
    sliced = dt[3..6]
    refute_nil sliced.parent, "Ruby-level parent must be set for GC"
  end

  # ---- F.2.6: kernel_iterator strip ----

  def test_kernel_iterator_strip_via_reduction
    dt = CArray.int64(5) {|i| i*10}.time(unit: :s)
    # reduction が parent (int64) として処理されることを確認 (= Face strip)
    assert_nothing_raised { dt.min }
    assert_nothing_raised { dt.max }
    assert_nothing_raised { dt.mean }
  end

  # ---- F.2.7: 主要演算子 ----

  def test_dt_plus_td
    dt = CArray.int64(3) {|i| (i+1)*100}.time(unit: :s)
    td = CArray.int64(3) {|i| (i+1)*10}.timedelta(unit: :s)
    r = dt + td
    assert_kind_of CATime, r
    assert_equal :s, r.unit.base
    assert_equal [110, 220, 330], r.parent.to_a
  end

  def test_dt_minus_dt_yields_td
    dt1 = CArray.int64(3) {|i| (i+1)*100}.time(unit: :s)
    dt2 = CArray.int64(3) {|i| (i+1)*50}.time(unit: :s)
    r = dt1 - dt2
    assert_kind_of CATimedelta, r
    assert_equal [50, 100, 150], r.parent.to_a
  end

  def test_dt_minus_td_yields_dt
    dt = CArray.int64(3) {|i| (i+1)*100}.time(unit: :s)
    td = CArray.int64(3) {|i| (i+1)*10}.timedelta(unit: :s)
    r = dt - td
    assert_kind_of CATime, r
  end

  def test_dt_plus_dt_raises
    dt1 = CArray.int64(3) { 100 }.time(unit: :s)
    dt2 = CArray.int64(3) { 50  }.time(unit: :s)
    assert_raise(TypeError) { dt1 + dt2 }
  end

  def test_td_plus_dt_commutative
    dt = CArray.int64(3) { 100 }.time(unit: :s)
    td = CArray.int64(3) { 10  }.timedelta(unit: :s)
    r = td + dt
    assert_kind_of CATime, r
    assert_equal [110]*3, r.parent.to_a
  end

  def test_td_times_integer
    td = CArray.int64(3) {|i| (i+1)*10}.timedelta(unit: :s)
    r = td * 3
    assert_kind_of CATimedelta, r
    assert_equal [30, 60, 90], r.parent.to_a
  end

  def test_comparison_returns_bool_carray
    dt1 = CArray.int64(3) {|i| (i+1)*100}.time(unit: :s)
    dt2 = CArray.int64(3) {|i| (i+1)*50}.time(unit: :s)
    bool = dt2 < dt1
    assert_kind_of CArray, bool, "comparison strips Face -> plain CArray"
  end

  def test_cross_unit_arithmetic
    # dt is the anchor: dt +/- td keeps dt's unit and converts the duration into
    # it, truncating a finer duration (no raise for a mere unit difference).
    dt = CArray.int64(3) { 1000 }.time(unit: :s)
    r  = dt + CArray.int64(3) { 500 }.timedelta(unit: :ns)   # 500 ns -> 0 s
    assert_equal :s, r.unit.base
    assert_equal dt.ticks.to_a, r.ticks.to_a
    r2 = dt + CArray.int64(3) { 2 }.timedelta(unit: :ms)     # 2 ms -> 0 s too
    assert_equal dt.ticks.to_a, r2.ticks.to_a
    # a coarser duration widens exactly
    r3 = CArray.int64(3) { 0 }.time(unit: :h) + CArray.int64(3) { 1 }.timedelta(unit: :D)
    assert_equal [24, 24, 24], r3.ticks.to_a       # 1 day = 24 h
    # but a cross-group (fixed time + calendar duration) still raises
    assert_raise(ArgumentError) { dt + CArray.int64(3) { 1 }.timedelta(unit: :M) }
  end

  def test_datetime_widens_integer_receiver_but_raises_on_float
    # int64 receiver -> zero-copy wrap (same storage entity)
    a  = CA_INT64([0, 86400])
    assert a.time(unit: :s).ticks.equal?(a)
    # narrower integer types widen to int64 (a copy) and interpret correctly
    assert_equal "1970-01-02", CA_INT32([0, 1, 2]).time(unit: :D)[1].to_s
    assert_equal 5, CA_UINT16([5, 10]).timedelta(unit: :h)[0].value
    # origin path works through the widen too
    o = CA_INT32([0, 1, 2]).time(unit: "3 hours", origin: "2022-01-01T09:00")
    assert_equal "2022-01-01T12:00:00Z", o[1].to_s
    # a Float / boolean receiver is lossy / non-integer -> raise
    assert_raise(TypeError) { CA_DOUBLE([1.0]).time(unit: :s) }
    assert_raise(TypeError) { CA_BOOLEAN([1]).timedelta(unit: :s) }
  end

  def test_minmax_returns_datetime_pair
    dt = CArray.time(%w[2024-06-15 2024-06-10 2024-06-20], unit: :D)
    lo, hi = dt.minmax
    assert_instance_of CATime::Element, lo
    assert_equal "2024-06-10", lo.to_s
    assert_equal "2024-06-20", hi.to_s
    assert_equal :D, lo.unit.base    # extremes are exact elements: storage unit kept
    # per-axis returns a [CATime, CATime] pair
    dt2 = CArray.time(%w[2024-06-15 2024-06-10 2024-06-20 2024-06-01], unit: :D).reshape(2, 2)
    plo, phi = dt2.minmax(axis: 1)
    assert_instance_of CATime, plo
    assert_equal ["2024-06-10", "2024-06-01"], [plo[0].to_s, plo[1].to_s]
    # timedelta too
    tlo, thi = CA_INT64([5, 2, 9]).timedelta(unit: :h).minmax
    assert_equal [2, 9], [tlo.value, thi.value]
  end

  def test_cross_unit_widen_overflow_raises_not_silent
    # widening a wide range into a fine unit overflows int64 -> raise loudly
    # (never a silent wrap).  td + td promotes to the finer unit (:ns here).
    big = CArray.int64(1) { 10**14 }.timedelta(unit: :D)   # 1e14 days -> ns overflows
    assert_raise(RangeError) { big + CArray.int64(1) { 1 }.timedelta(unit: :ns) }
    # dt - dt likewise (5000 AD in seconds -> ns overflows)
    a = CArray.time("5000-01-01", unit: :s)
    b = CArray.time("1970-01-01", unit: :ns)
    assert_raise(RangeError) { a - b }
    # an in-range mix is fine
    ok = CArray.int64(1) { 2 }.timedelta(unit: :D) + CArray.int64(1) { 5 }.timedelta(unit: :ns)
    assert_equal :ns, ok.unit.base
    assert_equal 2 * 86400 * 10**9 + 5, ok[0].value
  end

  # ---- F.2.8: Scalar return ----

  def test_scalar_return_class
    dt = CArray.int64(5) {|i| i*86400}.time(unit: :s)
    s = dt[2]
    assert_kind_of CATime::Element, s
    assert_equal 2*86400, s.value
    assert_equal :s, s.unit.base
  end

  def test_scalar_to_time_utc
    dt = CArray.int64(1) { 86400 }.time(unit: :s)
    t = dt[0].to_time
    assert_kind_of Time, t
    assert_equal "1970-01-02T00:00:00Z", t.iso8601
  end

  def test_scalar_comparable
    dt = CArray.int64(3) {|i| i}.time(unit: :s)
    assert dt[0] < dt[1]
    assert dt[2] > dt[1]
  end

  def test_timedelta_scalar
    td = CArray.int64(3) {|i| (i+1)*60}.timedelta(unit: :s)
    s = td[1]
    assert_kind_of CATimedelta::Element, s
    assert_equal 120, s.value
    assert_equal "120s", s.to_s
  end

  # ---- F.2.9: reduction wrap policy ----

  def test_dt_min_max_mean_returns_scalar
    dt = CArray.int64(5) {|i| i*10}.time(unit: :s)
    assert_kind_of CATime::Element, dt.min
    assert_kind_of CATime::Element, dt.max
    assert_kind_of CATime::Element, dt.mean
    assert_equal 0,  dt.min.value
    assert_equal 40, dt.max.value
    # min / max keep the storage unit; mean resolves to :ns (§8), so compare the
    # instant rather than the raw count
    assert_equal 20, dt.mean.to_time.to_i   # 20 s since the epoch
  end

  def test_dt_sum_raises
    dt = CArray.int64(5) {|i| i*10}.time(unit: :s)
    assert_raise(TypeError) { dt.sum }
  end

  def test_dt_variance_raises_stddev_is_a_timedelta
    dt = CArray.int64(5) {|i| i*10}.time(unit: :s)
    assert_raise(TypeError) { dt.variance }   # squared-time units, no type
    # stddev is the spread as a duration -> CATimedelta
    assert_kind_of CATimedelta::Element, dt.stddev
  end

  def test_td_sum_mean_returns_scalar
    td = CArray.int64(5) {|i| (i+1)*60}.timedelta(unit: :s)
    assert_kind_of CATimedelta::Element, td.sum
    assert_kind_of CATimedelta::Element, td.mean
    assert_equal 60+120+180+240+300, td.sum.value
  end

  def test_dt_reduction_reports_on_the_arrays_own_grid
    require "time"
    # :D storage: the centroid lands between two days, and the answer comes
    # back on the day grid (nearest tick).  A caller who wants the half day
    # declares the finer grid first, with to_unit.
    dt = CArray.time(%w[2024-06-15 2024-06-16], unit: :D)
    assert_equal :D, dt.mean.unit.base
    assert_equal Time.utc(2024, 6, 16), dt.mean.to_time      # 19889.5 -> 19890
    assert_equal Time.utc(2024, 6, 16), dt.median.to_time
    assert_equal :h, dt.to_unit(:h).mean.unit.base
    assert_equal Time.utc(2024, 6, 15, 12), dt.to_unit(:h).mean.to_time
    # calendar storage stays in month ordinals (no drop into day space)
    m = CArray.time(%w[2024-01-01 2024-04-01], unit: :M)
    assert_equal :M, m.mean.unit.base
    assert_equal Time.utc(2024, 3, 1), m.mean.to_time        # (648 + 651) / 2 = 649.5 -> 650
    # stddev is a duration, on the array's unit
    assert_kind_of CATimedelta::Element, dt.stddev
    assert_equal :D, dt.stddev.unit.base
    # a wide range no longer raises: the output grid is the array's own
    far = CArray.time(%w[1600-01-01 2400-01-01], unit: :D)
    assert_equal :D, far.mean.unit.base
    assert_equal Time.utc(2000, 1, 1), far.mean.to_time
    # per-axis re-lifts (was a bare float array before)
    mat = CArray.time(%w[2024-06-15 2024-06-17 2024-06-19 2024-06-21], unit: :D).reshape(2, 2)
    pa = mat.mean(axis: 1)
    assert_instance_of CATime, pa
    assert_equal [Time.utc(2024, 6, 16), Time.utc(2024, 6, 20)], pa.to_time.to_a
    assert_instance_of CATimedelta, mat.stddev(axis: 1)
  end

  # ---- F.2.10: numpy/pandas 風 helper ----

  def test_date_range
    dr = CArray.time_series("2024-01-01", count: 5, unit: :D)
    assert_kind_of CATime, dr
    assert_equal :D, dr.unit.base
    assert_equal 5, dr.elements
    # F.4.x semantic 修正: int64 value は unit-scaled (= :D なら day count)、
    # 連続日 unit :D で step = 1。旧 +86400 (= seconds) 期待値は誤り。
    diffs = dr.parent.to_a.each_cons(2).map { |a, b| b - a }
    assert_equal [1, 1, 1, 1], diffs
  end

  def test_date_range_unsupported_freq
    assert_raise(ArgumentError) do
      CArray.time_series("2024-01-01", count: 5, unit: :unsupported)
    end
  end

  def test_datetime_literal_parse
    ts = CArray.time("2024-01-15", unit: :D)
    assert_kind_of CATime, ts
    assert_equal :D, ts.unit.base
    assert_equal 1, ts.elements
  end

  # ---- L0 invariants (= Phase 2 で flag activation 確認) ----

  def test_l0_face_subclass_data_layout_identical_to_parent
    raw = CArray.int64(5)
    dt = CATime.wrap(raw, unit: :ns)
    assert_equal raw.bytes, dt.bytes, "Face must share storage byte size"
    assert_equal raw.ndim,  dt.ndim,  "Face must share ndim"
    assert_equal raw.dim,   dt.dim,   "Face must share shape"
  end

  def test_l0_no_value_conversion_through_face
    raw = CArray.int64(5) {|i| i * 1000}
    dt = raw.time(unit: :ns)
    # storage 経由で見ても、Face 経由で見ても同じ int64 値
    assert_equal raw.to_a, dt.parent.to_a
  end

  # ---- F.2.13: view-creating method lift hook deployment (Q4 (β)) ----

  def test_transpose_preserves_face
    dt = CArray.int64(3, 4) {|i, j| i*4 + j}.time(unit: :s)
    t = dt.transpose
    assert_kind_of CATime, t
    assert_equal :s, t.unit.base
    assert_equal [4, 3], t.dim
  end

  def test_reshape_preserves_face
    dt = CArray.int64(6) {|i| i*10}.time(unit: :s)
    r = dt.reshape(2, 3)
    assert_kind_of CATime, r
    assert_equal :s, r.unit.base
    assert_equal [2, 3], r.dim
  end

  def test_flip_reverse_roll_preserve_face
    dt = CArray.int64(5) {|i| i*10}.time(unit: :ns)
    assert_kind_of CATime, dt.flip
    assert_kind_of CATime, dt.reverse
    assert_kind_of CATime, dt.roll(1)
    assert_equal :ns, dt.flip.unit.base
    assert_equal [40, 30, 20, 10, 0], dt.flip.parent.to_a
  end

  def test_sort_preserves_face
    dt = CArray.int64(5) {|i| (4-i)*10}.time(unit: :s)
    sorted = dt.sort
    assert_kind_of CATime, sorted
    assert_equal :s, sorted.unit.base
    assert_equal [0, 10, 20, 30, 40], sorted.parent.to_a
  end

  def test_copy_to_ca_preserve_face
    dt = CArray.int64(5) {|i| i*100}.time(unit: :s)
    c = dt.copy
    assert_kind_of CATime, c
    assert_equal :s, c.unit.base
    tc = dt.to_ca
    assert_kind_of CATime, tc
    assert_equal :s, tc.unit.base
  end

  def test_view_lift_chain_composability
    # Face は chain 経由でも保持される
    dt = CArray.int64(12) {|i| i*100}.time(unit: :s)
    chain = dt.reshape(3, 4).transpose.flip
    assert_kind_of CATime, chain
    assert_equal :s, chain.unit.base
  end

  def test_timedelta_view_methods_preserve_face
    td = CArray.int64(6) {|i| (i+1)*60}.timedelta(unit: :s)
    assert_kind_of CATimedelta, td.transpose
    assert_kind_of CATimedelta, td.reshape(2, 3)
    assert_kind_of CATimedelta, td.sort
    assert_kind_of CATimedelta, td.copy
    assert_equal :s, td.transpose.unit.base
  end

  # ---- F.2.15: 追加 view-creating method lift hook deployment ----

  def test_flatten_preserves_face
    dt = CArray.int64(2, 3) {|i, j| i*3 + j}.time(unit: :s)
    f = dt.flatten
    assert_kind_of CATime, f
    assert_equal :s, f.unit.base
    assert_equal 6, f.elements
  end

  def test_diagonal_preserves_face
    dt = CArray.int64(3, 3) {|i, j| i*3 + j}.time(unit: :s)
    d = dt.diagonal
    assert_kind_of CATime, d
    assert_equal :s, d.unit.base
  end

  def test_window_preserves_face
    dt = CArray.int64(4, 5) {|i, j| i*5 + j}.time(unit: :s)
    w = dt.window(0..1, 0..2)
    assert_kind_of CATime, w
    assert_equal :s, w.unit.base
  end

  def test_shift_preserves_face
    dt = CArray.int64(5) {|i| i*10}.time(unit: :s)
    assert_kind_of CATime, dt.shift(1)
  end

  def test_tile_preserves_face
    dt = CArray.int64(3) {|i| i*10}.time(unit: :s)
    assert_kind_of CATime, dt.tile(2)
  end

  def test_value_preserves_face_with_lift
    raw = CArray.int64(5) {|i| i*10}
    dt = raw.time(unit: :s)
    v = dt.value
    assert_kind_of CATime, v, "value should be lifted back to Face"
    assert_equal :s, v.unit.base
  end

  # The lift puts the Face on top of the refer that carries the data, so
  # the value-array marking has to reach the refer as well.  Marking only
  # the wrapper left the refer answering "masked" from its parent, and a
  # kernel -- which strips Faces at entry and meets exactly that refer --
  # went on skipping cells whose values it was being asked to read.
  def test_value_drops_the_mask_below_the_face_too
    raw = CA_INT64([10, 20, 30, 40])
    raw[0] = UNDEF
    dt = raw.time(unit: :D)

    assert_false dt.value.has_mask?
    assert_false dt.value.parent.has_mask?
    assert_true  dt.value.parent.value_array?
    assert_equal 0, dt.value.count_masked
  end

  def test_a_kernel_over_value_sees_the_masked_cell
    raw = CA_INT64([10, 20, 30, 40])
    raw[0] = UNDEF
    dt = raw.time(unit: :D)

    assert_equal 10, raw.value.min                 # storage, for reference
    assert_equal 10, dt.value.min.value            # the Face must agree
    assert_equal 20, dt.min.value                  # ... and still mask on dt
  end

  def test_strip_mask_preserves_face
    raw = CArray.int64(5) {|i| i*10}
    dt = raw.time(unit: :s)
    s = dt.strip_mask(0)
    assert_kind_of CATime, s
  end

  def test_select_via_mask_index_preserves_face
    dt = CArray.int64(6) {|i| i*10}.time(unit: :s)
    mask = CArray.boolean(6) {|i| i.even?}
    sel = dt[mask]
    assert_kind_of CATime, sel
  end

  def test_partition_preserves_face
    dt = CArray.int64(5) {|i| (4-i)*10}.time(unit: :s)
    p = dt.partition(2)
    assert_kind_of CATime, p
    assert_equal :s, p.unit.base
  end

  # ---- write leg (Phase 1 marker、Phase 2 で transparently 動作) ----

  def test_write_through_face_propagates_to_parent
    raw = CArray.int64(5) {|i| i}
    dt = raw.time(unit: :s)
    dt[0..2] = [100, 200, 300]
    assert_equal [100, 200, 300, 3, 4], raw.to_a, "write must propagate to parent"
  end
end

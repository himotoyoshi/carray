# frozen_string_literal: true
#
# Value-returning members that test_face_family_matrix.rb does not enumerate,
# and the stores they lean on.  Each one handed a Face's storage back as a
# plain array (8-byte strings for a CATime), dropped the class, or refused to
# take a Face at all.

require "test/unit"
require "carray"
require "carray/categorical"

class TestFaceReliftGaps < Test::Unit::TestCase

  def ticks
    CArray.int64(5) { |i| [256, 255, 1, 300, 7][i] }.timedelta(unit: :s)
  end

  def days
    CArray.time(%w[2024-01-01 2024-01-03 2024-01-02 2024-01-04 2024-01-09],
                unit: :D)
  end

  def strings
    CArray.const_string(%w[ab dd cd ee zz])
  end

  def shown (a)
    a.to_a.map { |e| e.equal?(UNDEF) ? e : e.to_s }
  end

  # ---- store: a Face array into a Face -----------------------------------

  def test_whole_boolean_and_address_stores_take_a_face
    d = days
    cond = CA_BOOLEAN([1, 0, 1, 0, 0])
    e = d.copy; e[] = d.reverse
    assert_kind_of CATime, e
    assert_equal %w[2024-01-09 2024-01-04 2024-01-02 2024-01-03 2024-01-01], shown(e)
    e = d.copy; e[cond] = d.reverse[cond]
    assert_equal %w[2024-01-09 2024-01-03 2024-01-02 2024-01-04 2024-01-09], shown(e)
    e = d.copy; e[CA_INT64([0, 2])] = d[CA_INT64([1, 3])]
    assert_equal %w[2024-01-03 2024-01-03 2024-01-04 2024-01-04 2024-01-09], shown(e)
  end

  def test_store_reconciles_the_unit
    e = days.copy
    e[] = CArray.time(Array.new(5, "2024-02-01"), unit: :h)
    assert_equal Array.new(5, "2024-02-01"), shown(e)
  end

  def test_store_keeps_the_raw_storage_escape
    e = days.copy
    e[] = CA_INT64([0, 1, 2, 3, 4])
    assert_equal "1970-01-02", e[1].to_s
    assert_raise(TypeError) { e[] = CA_FLOAT64([0, 1, 2, 3, 4]) }
  end

  # ---- cummax / cummin ------------------------------------------------------

  def test_cummax_cummin_answer_as_the_face
    t = ticks
    assert_kind_of CATimedelta, t.cummax
    assert_equal [256, 256, 256, 300, 300], t.cummax.to_a.map(&:value)
    assert_equal [256, 255, 1, 1, 1],       t.cummin.to_a.map(&:value)
    assert_equal %w[2024-01-01 2024-01-03 2024-01-03 2024-01-04 2024-01-09],
                 shown(days.cummax)
    assert_kind_of CAString, strings.to_string.cummax
    assert_raise(ArgumentError) { CA_OBJECT(%w[a b]).categorize.cummax }
  end

  # ---- windows ----------------------------------------------------------------

  def test_window_reductions_answer_as_the_face
    t = ticks
    assert_kind_of CATimedelta, t.windows(-1..1).min
    assert_equal [255, 1, 1, 1, 7], t.windows(-1..1).min.to_a.map(&:value)
    assert_equal [256, 256, 300, 300, 300],
                 t.windows(-1..1, bounds: :nearest).max.to_a.map(&:value)
    assert_kind_of CATime, days.windows(-1..1).mean
    assert_equal %w[ab ab cd cd ee], strings.windows(-1..1).min.to_a
    assert_kind_of CAConstString, strings.windows(-1..1).min
    assert_kind_of CAString, strings.to_string.windows(-1..1).max
    assert_kind_of CAFixlenString, strings.to_fixlen_string.windows(-1..1).min
  end

  def test_window_constant_bound_takes_a_surface_value
    t = ticks
    r = t.windows(-1..1, bounds: :constant, fill_value: t[2]).max
    assert_equal [256, 256, 300, 300, 300], r.to_a.map(&:value)
  end

  def test_window_nearest_bound_on_a_fixlen_array
    a = CArray.fixlen(3, bytes: 2) { "ab" }
    assert_equal [3, 3, 3], a.windows(-1..1, bounds: :nearest).count.to_a
  end

  def test_sliding_windows_keeps_the_face
    assert_kind_of CATime, days.sliding_windows(2)
    assert_kind_of CATime, days.unfold(2)
  end

  # ---- blocks: reductions other than min / max --------------------------------

  def test_block_reductions_answer_as_the_face
    t = ticks
    assert_kind_of CATimedelta, t.blocks(2).mean
    assert_equal [256, 151, 7], t.blocks(2).mean.to_a.map(&:value)
    assert_equal [511, 301, 7], t.blocks(2).sum.to_a.map(&:value)
    assert_kind_of CATime, days.blocks(2).median
    assert_equal %w[2024-01-02 2024-01-03 2024-01-09], shown(days.blocks(2).mean)
    assert_kind_of CATimedelta, days.blocks(2).stddev
    m = t.copy; m[2..3] = UNDEF
    assert_equal [256, UNDEF, 7],
                 m.blocks(2).mean.to_a.map { |e| e.equal?(UNDEF) ? e : e.value }
  end

  # ---- then_else ------------------------------------------------------------------

  def test_then_else_answers_as_the_face
    t = ticks[0..3]
    cond = CA_BOOLEAN([1, 0, 1, 0])
    assert_kind_of CATimedelta, cond.then_else(t, t[1])
    assert_equal [256, 255, 1, 255],   cond.then_else(t, t[1]).to_a.map(&:value)
    assert_equal [255, 255, 255, 300], cond.then_else(t[1], t).to_a.map(&:value)
    assert_equal [256, 1, 1, 256],     cond.then_else(t, t.reverse).to_a.map(&:value)
    masked = cond.copy; masked[2] = UNDEF
    assert_equal [256, 1, UNDEF, 256],
                 masked.then_else(t, t.reverse).to_a.map { |e| e.equal?(UNDEF) ? e : e.value }
  end

  def test_then_else_on_string_faces
    s = strings[0..3]
    cond = CA_BOOLEAN([1, 0, 1, 0])
    r = cond.then_else(s, s.reverse)
    assert_kind_of CAConstString, r
    assert_equal %w[ab cd cd ab], r.to_a
    assert_kind_of CAFixlenString, cond.then_else(s.to_fixlen_string, "zz")
    c = CA_OBJECT(%w[ab dd cd ee]).categorize
    assert_equal %w[ab dd cd dd], cond.then_else(c, "dd").to_a
  end

  def test_broadcast_to_keeps_the_face
    t = days[0..3].reshape(1, 4).broadcast_to(2, 4)
    assert_kind_of CATime, t
    assert_equal "2024-01-02", t[1, 2].to_s
    assert t.read_only?
    assert_kind_of CATimedelta, ticks[0..3].reshape(1, 4).broadcast_to(3, 4)
    assert_kind_of CAConstString, strings[0..3].reshape(1, 4).broadcast_to(2, 4)
    c = CA_OBJECT(%w[x y x z]).categorize.reshape(1, 4).broadcast_to(2, 4)
    assert_kind_of CACategorical, c
    assert_equal "z", c[1, 3]
  end

  # to_comparable lifts a scalar to a length-1 array; a 2-D reference
  # compared it against shape [1] and refused.
  def test_scalar_compare_on_multi_dimensional_time
    t = days[0..3].reshape(2, 2)
    assert_equal [[true, false], [false, false]], t.eq(t[0, 0]).to_a
    assert_equal [[true, false], [true, false]], t.lt(t[0, 1]).to_a
    assert_equal [[true, false], [true, false]], (t < Time.utc(2024, 1, 3)).to_a
    assert_equal [[true, false], [false, false]], t.eq(days[0..3].to_unit(:h)[0]).to_a
    d = ticks[0..3].reshape(2, 2)
    assert_equal [[false, true], [false, false]], d.eq(d[0, 1]).to_a
  end

end

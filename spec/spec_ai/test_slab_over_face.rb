# each_slab / map_slab / reduce_slab over a Face hand each slab to the
# block as that Face, and answer in that Face: a block value is read the
# way the Face reads a stored value.  A read-only Face, which has no blank
# to write into, answers in object cells holding its surface values.  A
# data_type: from the caller passes through.  UNDEF from a reduce_slab
# block masks the cell, over any array.

require "test/unit"
require "carray"

class TestSlabOverFace < Test::Unit::TestCase

  DAYS = %w[2024-01-01 2024-01-02 2024-01-03 2024-01-04 2024-01-05 2024-01-06]

  def times
    CArray.time(DAYS).reshape(3, 2)
  end

  def strings (x)
    x.to_a.flatten.map(&:to_s)
  end

  def test_each_slab_yields_the_face
    seen = []
    times.each_slab(axis: 1) { |s| seen << [s.class, strings(s)] }
    assert_equal [[CATime, DAYS[0, 2]], [CATime, DAYS[2, 2]], [CATime, DAYS[4, 2]]], seen
    seen = []
    times.transpose.each_slab(axis: 1) { |s| seen << strings(s) }
    assert_equal [DAYS.values_at(0, 2, 4), DAYS.values_at(1, 3, 5)], seen
  end

  def test_slab_and_block_iterator_each_yield_the_face
    assert_equal [CATime] * 3, times[nil, :>].each.map(&:class)
    tiles = []
    times.blocks(2, 1).each { |x| tiles << [x.class, strings(x)] }
    assert_equal [CATime, %w[2024-01-01 2024-01-03]], tiles[0]
    assert_equal [CATime, %w[2024-01-06 UNDEF]], tiles[3]
  end

  def test_map_slab_answers_in_the_face
    r = times.map_slab(axis: 1) { |s| s }
    assert_kind_of CATime, r
    assert_equal DAYS, strings(r)
    r = times.map_slab(axis: 0) { |s| s.max }
    assert_equal %w[2024-01-05 2024-01-06] * 3, strings(r)
    r = times.map_slab(axis: 1) { |s| x = s.copy; x[0] = UNDEF; x }
    assert_equal %w[UNDEF 2024-01-02 UNDEF 2024-01-04 UNDEF 2024-01-06], strings(r)
    assert_kind_of CATime, times[nil, :>].map { |s| s }
  end

  def test_reduce_slab_answers_in_the_face
    r = times.reduce_slab(axis: 1) { |s| s.max }
    assert_kind_of CATime, r
    assert_equal %w[2024-01-02 2024-01-04 2024-01-06], strings(r)
    r = times.reduce_slab(axis: 1, init: nil) { |acc, e| acc.nil? || e > acc ? e : acc }
    assert_kind_of CATime, r
    assert_equal %w[2024-01-02 2024-01-04 2024-01-06], strings(r)
    r = times.reduce_slab(axis: 1) { |s| UNDEF }
    assert_equal %w[UNDEF UNDEF UNDEF], strings(r)
  end

  def test_a_data_type_from_the_caller_passes_through
    assert_equal [2, 2, 2], times.reduce_slab(axis: 1, data_type: :int64) { |s| s.elements }.to_a
    r = times.map_slab(axis: 1, data_type: :object) { |s| s }
    assert_equal [CATime::Element], r.to_a.flatten.map(&:class).uniq
  end

  def test_a_read_only_face_answers_its_surface_values
    c = CArray.const_string(%w[b a c d]).reshape(2, 2)
    r = c.map_slab(axis: 1) { |s| s }
    assert_equal :object, r.data_type
    assert_equal [%w[b a], %w[c d]], r.to_a
    assert_equal %w[a c], c.reduce_slab(axis: 1) { |s| s.min }.to_a
  end

  def test_undef_from_a_reduce_slab_block_masks_the_cell
    a = CArray.int32(3, 2).seq
    assert_equal [1, UNDEF, 1], a.reduce_slab(axis: 1) { |s| s[0] == 2 ? UNDEF : 1 }.to_a
    assert_equal [0, UNDEF, 0], a.reduce_slab(axis: 1, init: 0) { |x, e| e == 3 ? UNDEF : x }.to_a
    assert_equal [1.0, UNDEF, 9.0],
                 a.reduce_slab(axis: 1, data_type: :object) { |s| s[0] == 2 ? UNDEF : s.sum }.to_a
    assert_false a.reduce_slab(axis: 1) { |s| s.sum }.has_mask?
  end

end

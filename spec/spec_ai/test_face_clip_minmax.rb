require "test/unit"
require "carray"

# clip and minmax answer a Face in its own terms, as min and max do: an
# orderable Face is ordered by its storage and comes back as itself, its
# bounds and fill values are values of it, and a Face that cannot order its
# storage refuses, naming the conversion that gives its values.

class TestFaceClipMinmax < Test::Unit::TestCase

  # ORDERABLE and COMPARABLE, defined in Ruby.
  class PlainTicks < CAObject
    def initialize (parent)
      super(CA_FIXLEN, parent.shape, bytes: 8, storage: CA_INT64, parent: parent,
            face: true, orderable_storage: true, comparable_storage: true)
    end
    def storage_to_element (raw)
      raw.is_a?(String) ? raw.unpack1("q") : raw
    end
  end

  def time (*s)
    CArray.time(s, unit: :D)
  end

  def strings (a)
    a.to_a.map(&:to_s)
  end

  def test_clip_keeps_a_time_array_and_reads_its_bounds_as_times
    t = time("2024-01-01", "2024-01-05", "2024-01-09")
    lo = time("2024-01-03")[0]
    hi = Time.utc(2024, 1, 7)
    r = t.clip(lo, hi)
    assert_kind_of CATime, r
    assert_equal %w[2024-01-03 2024-01-05 2024-01-07], strings(r)
    assert_equal [true, false, true], t.clip(lo, hi, UNDEF).is_masked.to_a
    assert_equal %w[2000-01-01 2024-01-05 2024-01-07],
                 strings(t.clip(lo, hi, lfill: Time.utc(2000, 1, 1)))
    assert_raise(TypeError) { t.clip(1, 2) }
  end

  def test_clip_orders_a_record_array_by_its_declared_members
    rec = CArray.struct(order_by: [:x]) { int32 :x }
    r = CARecord.new(rec, 3)
    r["x"][] = [300, 1, 2]
    c = r.clip(r[1], r[2])
    assert_kind_of CARecord, c
    assert_equal [2, 1, 2], c.to_a.map(&:x)
  end

  def test_clip_refuses_a_face_that_cannot_order_its_storage
    k = CArray.string(%w[b a]).categorize
    e = assert_raise(ArgumentError) { k.clip("a", "b") }
    assert_match(/to_type\(:object\) gives its values/, e.message)
  end

  def test_clip_on_strings_orders_their_values
    c = CArray.const_string(%w[b a z])
    assert_kind_of CAConstString, c.clip("b", "y")
    assert_equal %w[b b y], c.clip("b", "y").to_a
    assert_equal %w[b b b], CArray.string(%w[b a c]).clip("b", "b").to_a
  end

  def test_minmax_answers_a_face_as_min_and_max_do
    p = PlainTicks.new(CA_INT64([[3, 1], [7, 0]]))
    assert_equal [p.min, p.max], p.minmax
    lo, hi = p.minmax(axis: 0)
    assert_kind_of PlainTicks, lo
    assert_kind_of PlainTicks, hi
    assert_equal [3, 0], lo.parent.to_a
    assert_equal [7, 1], hi.parent.to_a
    k = CArray.string(%w[b a]).categorize
    e = assert_raise(ArgumentError) { k.minmax }
    assert_match(/to_type\(:object\) gives its values/, e.message)
  end

  def test_minmax_of_a_time_array_is_its_earliest_and_latest
    t = time("2024-01-05", "2024-01-01", "2024-02-09")
    assert_equal %w[2024-01-01 2024-02-09], t.minmax.map(&:to_s)
    m = t.copy
    m[] = UNDEF
    assert_equal %w[2024-01-09 2024-01-09], m.minmax(fill_value: Time.utc(2024, 1, 9)).map(&:to_s)
  end
end

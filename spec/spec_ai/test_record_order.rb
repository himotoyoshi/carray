# frozen_string_literal: true
#
# A record orders by the members its struct names in order_by:, compared in
# that order.  The bytes of a record are no order of its values (a negative
# integer, a little-endian float), so a struct that declares no order has
# none, and the ordering members raise.

require "test/unit"
require "carray"

class TestRecordOrder < Test::Unit::TestCase

  Point = CArray.struct(pack: 1, order_by: [:lat, :id]) { float64 :lat; int32 :id }
  Plain = CArray.struct(pack: 1) { float64 :lat; int32 :id }

  def records (lat: [3.0, -1.0, -1.0, 2.0], id: [1, 2, 0, 3], type: Point)
    r = CARecord.new(type, lat.size)
    r["lat"] = CA_FLOAT64(lat)
    r["id"]  = CA_INT32(id)
    r
  end

  def pairs (a)
    a.to_a.map { |e| e.equal?(UNDEF) ? e : [e.lat, e.id] }
  end

  # ---- the struct ------------------------------------------------------------

  def test_order_by_is_declared_on_the_struct
    assert_equal %w[lat id], Point.order_by
    assert_nil Plain.order_by
    assert_raise(CAStruct::DefinitionError) {
      CArray.struct(order_by: [:z]) { int32 :a }
    }
    assert_raise(CAStruct::DefinitionError) {
      CArray.struct(order_by: [:inner]) { struct(:inner) { int32 :a } }
    }
  end

  def test_records_compare_by_the_declared_members
    a = Point.new(lat: -1.0, id: 2)
    b = Point.new(lat: -1.0, id: 0)
    c = Point.new(lat: 2.0, id: 0)
    assert_equal 1, a <=> b
    assert a > b
    assert a < c
    assert_equal 0, a <=> Point.new(lat: -1.0, id: 2)
    assert_equal [b, a, c], [c, a, b].sort
    assert_equal a, Point.new(lat: -1.0, id: 2)
  end

  def test_a_struct_without_order_by_has_no_order
    a = Plain.new(lat: 1.0, id: 0)
    assert_nil a <=> Plain.new(lat: 2.0, id: 0)
    assert_raise(ArgumentError) { a < Plain.new(lat: 2.0, id: 0) }
    r = records(type: Plain)
    [:sort, :sort_index, :sort_addr, :min, :max, :min_index, :rank_index].each do |m|
      assert_raise(ArgumentError, m.to_s) { r.public_send(m) }
    end
    assert_raise(ArgumentError) { r.partition_copy(1) }
    assert_raise(ArgumentError) { r < r[0] }
  end

  # ---- a record array --------------------------------------------------------

  def test_sort_family
    r = records
    assert_kind_of CARecord, r.sort
    assert_equal [[-1.0, 0], [-1.0, 2], [2.0, 3], [3.0, 1]], pairs(r.sort)
    assert_equal [2, 1, 3, 0], r.sort_index.to_a
    assert_equal [3, 1, 0, 2], r.order.to_a
    assert_equal pairs(r.sort), pairs(r.sort_copy)
  end

  def test_min_max
    r = records
    assert_equal [-1.0, 0], r.min.values
    assert_equal [3.0, 1],  r.max.values
    assert_equal [[-1.0, 0], [3.0, 1]], r.minmax.map(&:values)
    assert_equal 2, r.min_index
    m = r.reshape(2, 2)
    assert_kind_of CARecord, m.min(axis: 1)
    assert_equal [[-1.0, 2], [-1.0, 0]], pairs(m.min(axis: 1))
    assert_equal [1, 2], m.min(axis: 0, keep_axis: true).shape
  end

  def test_partition_copy
    r = records.partition_copy(1)
    assert_kind_of CARecord, r
    assert_equal [-1.0, 2], r[1].values
  end

  def test_comparison_operators
    r = records
    assert_equal [false, true, true, false], (r < r[3]).to_a
    assert_equal [false, false, true, true], (r < r.reverse).to_a
    assert_equal [1, 0, -1, 1], (r <=> r[1]).to_a
    assert_raise(ArgumentError) { r < records(type: Plain)[0] }
  end

  def test_nan_sorts_last_and_masked_records_stay_masked
    r = records(lat: [Float::NAN, 1.0, 2.0], id: [0, 0, 0])
    assert_equal [1.0, 2.0], r.sort.to_a.first(2).map(&:lat)
    assert r.sort[2].lat.nan?
    assert_equal 1, r[0] <=> r[1]
    m = records
    m[1] = UNDEF
    assert_equal [[-1.0, 0], [2.0, 3], [3.0, 1], UNDEF], pairs(m.sort)
    assert_equal [-1.0, 0], m.min.values
  end

end

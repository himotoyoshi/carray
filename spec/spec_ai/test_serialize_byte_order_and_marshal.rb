# frozen_string_literal: true
#
# Two round trips that failed for arrays the format otherwise handles:
#
#   - a record array written big-endian came back with every record reversed
#     whole: the writer swaps member by member, the reader swapped the bare
#     fixlen before the trailer said where the members were
#   - Marshal of a view or a scalar wrote a plain array under the view's own
#     class, and load could not put a plain array into it

require "test/unit"
require "carray"

class TestSerializeByteOrderAndMarshal < Test::Unit::TestCase

  R = CArray.struct(pack: 1) { int32 :x; float64 :y; int16 :z }

  def records
    r = CARecord.new(R, 3)
    r["x"] = CA_INT32([1, -2, 3])
    r["y"] = CA_FLOAT64([2.5, -1e300, 0.0])
    r["z"] = CA_INT16([7, 8, -9])
    r[2] = UNDEF
    r
  end

  def values (r)
    r.to_a.map { |e| e.equal?(UNDEF) ? e : e.values }
  end

  # ---- byte order --------------------------------------------------------

  def test_a_record_array_round_trips_in_either_byte_order
    [CA_BIG_ENDIAN, CA_LITTLE_ENDIAN].each do |endian|
      b = CArray.load(CArray.dump(records, endian: endian))
      assert_kind_of CARecord, b
      assert_equal [[1, 2.5, 7], [-2, -1e300, 8], UNDEF], values(b), endian.to_s
    end
  end

  def test_a_masked_numeric_array_round_trips_in_either_byte_order
    a = CA_FLOAT64([1.5, -2.0, 3.0])
    a[1] = UNDEF
    [CA_BIG_ENDIAN, CA_LITTLE_ENDIAN].each do |endian|
      assert_equal [1.5, UNDEF, 3.0], CArray.load(CArray.dump(a, endian: endian)).to_a
    end
  end

  # ---- Marshal ------------------------------------------------------------

  def round_trip (obj)
    Marshal.load(Marshal.dump(obj))
  end

  def test_a_view_marshals_as_a_plain_array
    a = CArray.int32(4).seq!
    [a[1..2], a.reshape(2, 2).transpose, a.lazy + 1].each do |v|
      r = round_trip(v)
      assert_instance_of CArray, r
      assert_equal v.to_a, r.to_a
    end
    m = a.copy
    m[1] = UNDEF
    assert_equal [0, UNDEF, 2], round_trip(m[0..2]).to_a
    assert_equal [1, "a"], round_trip(CA_OBJECT([1, "a", nil])[0..1]).to_a
  end

  def test_a_scalar_marshals_as_a_scalar
    s = CScalar.new(:int32)
    s[0] = 3
    r = round_trip(s)
    assert_instance_of CScalar, r
    assert_equal [3], r.to_a
    m = CScalar.new(:float64)
    m[0] = UNDEF
    assert_equal [UNDEF], round_trip(m).to_a
    o = CScalar.new(:object)
    o[0] = [1, 2]
    assert_equal [[1, 2]], round_trip(o).to_a
  end

  def test_a_record_array_keeps_its_class_through_marshal
    r = round_trip(records)
    assert_kind_of CARecord, r
    assert_equal values(records), values(r)
    assert_kind_of CARecord, round_trip(records[0..1])
  end

  def test_marshal_refuses_what_it_cannot_carry
    assert_raise(TypeError) { Marshal.dump(CArray.time(%w[2024-01-01], unit: :D)) }
    w = CArray.wrap_memory_view(CArray.int32(2).seq!)
    assert_raise(TypeError) { Marshal.dump(w) }
    assert_equal [0, 1], round_trip(w.copy).to_a
  end

end

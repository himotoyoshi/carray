require "test/unit"
require "carray"

# A _CARRAY3 payload whose header fields disagree is refused before the
# array is allocated; a record layout that does not fit its record is
# refused wherever it comes from; a Face that the format cannot carry is
# refused on save.
class TestSerializeCorrupt < Test::Unit::TestCase

  SER = CArray::Serializer
  KEYS = %i[has_mask has_trailer data_type_code ndim shape element_bytes
            flags elements data_offset data_bytes mask_offset mask_bytes
            trailer_offset trailer_bytes]

  def good
    CArray.dump(CArray.float64(3, 4).seq!)
  end

  def patch (s, fields)
    h = SER.unpack_header(s[0, 256], CArray.endian).merge(fields)
    SER.pack_header(KEYS.to_h { |k| [k, h[k]] }, CArray.endian) + s[256..]
  end

  def assert_corrupt (s, pattern)
    e = assert_raise(ArgumentError) { CArray.load(s) }
    assert_match pattern, e.message
  end

  def test_good_round_trip
    assert_equal CArray.float64(3, 4).seq!, CArray.load(good)
  end

  def test_shape_disagreeing_with_elements
    assert_corrupt patch(good, shape: [1, 4] + [0] * 14), /does not hold 12 elements/
    assert_corrupt patch(good, shape: [30, 40] + [0] * 14), /does not hold 12 elements/
  end

  def test_ndim_out_of_range
    assert_corrupt patch(good, ndim: 0), /ndim 0 out of/
    assert_corrupt patch(good, ndim: 17, shape: [1] * 16), /ndim 17 out of/
  end

  def test_element_bytes_disagreeing_with_data_type
    assert_corrupt patch(good, element_bytes: 4, data_bytes: 48), /element_bytes 4/
    assert_corrupt patch(good, data_type_code: CArray.data_type_code(:int8)),
                   /element_bytes 8 for data type int8/
  end

  def test_mask_bytes_disagreeing_with_has_mask
    assert_corrupt patch(good, has_mask: 1), /mask_bytes/
  end

  def test_declared_size_larger_than_the_source
    big = patch(good, data_type_code: CArray.data_type_code(:fixlen),
                      element_bytes: 10**9, data_bytes: 12 * 10**9)
    assert_corrupt big, /declares 12000000000 bytes/
    assert_corrupt patch(good, trailer_bytes: 50), /declares 146 bytes/
  end

  Rec = CArray.struct(pack: 1) { int32 :x; float64 :y }

  def record_with_schema (schema)
    r = CARecord.new(Rec, 3)
    3.times { |i| r[i] = Rec.new(x: i, y: i + 0.5) }
    s = CArray.dump(r)
    h = SER.unpack_header(s[0, 256], CArray.endian)
    tr = SER.allocate.send(:encode_trailer, { "data_class" => schema })
    body = s[256, h[:trailer_offset] - 256]
    h = h.merge(trailer_bytes: tr.bytesize)
    SER.pack_header(KEYS.to_h { |k| [k, h[k]] }, CArray.endian) + body + tr
  end

  def schema (members, record_bytes: 12)
    { "kind" => "struct", "record_bytes" => record_bytes, "members" => members }
  end

  def test_schema_member_outside_its_record
    neg = schema([{ "name" => "x", "type" => "i", "offset" => 0 },
                  { "name" => "y", "type" => "d", "offset" => -4 }])
    assert_raise(CAStruct::DefinitionError) { CArray.load(record_with_schema(neg)) }
    over = schema([{ "name" => "x", "type" => "i", "offset" => 11 },
                   { "name" => "y", "type" => "d", "offset" => 4 }])
    assert_raise(CAStruct::DefinitionError) { CArray.load(record_with_schema(over)) }
  end

  def test_schema_record_size_disagreeing_with_the_elements
    s = record_with_schema(schema([{ "name" => "x", "type" => "i", "offset" => 0 }],
                                  record_bytes: 1200))
    assert_raise(ArgumentError) { CArray.load(s) }
  end

  def test_schema_not_a_mapping
    assert_corrupt record_with_schema(5), /data_class schema/
    assert_corrupt record_with_schema(schema([1, 2])), /data_class schema/
  end

  def test_struct_member_offsets
    assert_raise(CAStruct::DefinitionError) {
      CArray.struct(pack: 1, size: 12) { member :int32, :x, offset: 0; member :float64, :y, offset: -4 }
    }
    assert_raise(CAStruct::DefinitionError) {
      CArray.struct(pack: 1, size: 12) { member :int32, :x, offset: 11; member :float64, :y, offset: 4 }
    }
    s = CArray.struct(pack: 1) { member :int32, :x, offset: 11; member :float64, :y, offset: 4 }
    assert_equal 15, s::DATA_SIZE
  end

  def test_record_wrap_of_mismatched_elements
    assert_raise(ArgumentError) { CARecord.wrap(CArray.new(:fixlen, [3], bytes: 8), Rec) }
    assert_kind_of CARecord, CARecord.wrap(CArray.new(:fixlen, [3], bytes: 12), Rec)
  end

  def test_save_refuses_a_face
    t = CArray.int64(3) { |i| i * 3600 }.time(unit: :s)
    assert_raise(TypeError) { CArray.dump(t) }
    assert_raise(TypeError) { CArray.dump(t[0..1]) }
    assert_equal [0, 3600, 7200], CArray.load(CArray.dump(t.parent)).to_a
    assert_kind_of CARecord, CArray.load(CArray.dump(CARecord.new(Rec, 2)))
  end
end

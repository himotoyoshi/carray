# _CARRAY3 portable binary format (PROPOSAL_SERIALIZE_3_0.md).
#
# Coverage: header layout at fixed offsets, numeric + mask round-trip,
# fixed data offset for cross-language readers, attribute trailer
# (including non-finite Floats), data_class Layer 1 schema + named /
# anonymous round-trip, endian override, CA_OBJECT refusal on the
# portable path, and the separated Marshal path.

require 'test/unit'
require 'carray'
require 'stringio'

class TestSerialize30 < Test::Unit::TestCase

  M      = "_CARRAY3"
  HDR    = 256
  MARKER = 0x01020304

  # host-endian unpack suffix for peeking into a dumped buffer
  E = (CArray.endian == CA_LITTLE_ENDIAN) ? "<" : ">"

  # ---- header ----

  def test_magic_and_header_size
    s = CArray.dump(CArray.int32(3).seq)
    assert_equal M, s.byteslice(0, 8)
    assert_operator s.bytesize, :>=, HDR
    assert_equal HDR, s[14, 2].unpack1("S#{E}")
  end

  def test_endian_marker_reads_native_on_same_endian_file
    s = CArray.dump(CArray.int32(3).seq)
    assert_equal MARKER, s[8, 4].unpack1("L#{E}")
  end

  def test_header_fields
    a = CArray.float64(2, 3).seq
    s = CArray.dump(a)
    assert_equal 1, s[12].ord           # version_major
    assert_equal 0, s[13].ord           # version_minor
    assert_equal 0, s[16].ord           # has_mask
    assert_equal 0, s[17].ord           # has_trailer
    assert_equal CArray.data_type_code(:float64), s[18].ord
    assert_equal 2, s[19].ord           # ndim
    assert_equal [2, 3], s[24, 16].unpack("q#{E}2")
    assert_equal 8, s[152, 4].unpack1("L#{E}")   # element_bytes
    assert_equal 6, s[160, 8].unpack1("Q#{E}")   # elements
    assert_equal HDR, s[168, 8].unpack1("Q#{E}")      # data_offset
    assert_equal 48,  s[176, 8].unpack1("Q#{E}")      # data_bytes
  end

  def test_flags_snapshot_written
    a = CArray.float64(2, 3).seq
    s = CArray.dump(a)
    assert_equal a.flags, s[156, 4].unpack1("l#{E}")
  end

  # ---- numeric payload ----

  def test_numeric_round_trip
    a = CArray.int32(10, 10) { 10 }
    a[5, 5] = UNDEF
    b = CArray.load(CArray.dump(a))
    assert_equal a, b
    assert b.has_mask?
  end

  def test_dump_is_deterministic
    a = CArray.int32(4, 4).seq
    a[1, 1] = UNDEF
    s1 = CArray.dump(a)
    s2 = CArray.dump(CArray.load(s1))
    assert_equal s1, s2
  end

  def test_data_lives_at_fixed_offset
    a = CArray.float64(3, 4).seq
    s = CArray.dump(a)
    assert_equal a.to_a.flatten, s[HDR, 96].unpack("d12")
  end

  def test_plain_numeric_has_no_trailer
    s = CArray.dump(CArray.int32(5).seq)
    assert_equal 0, s[200, 8].unpack1("Q#{E}")   # trailer_offset
    assert_equal 0, s[208, 8].unpack1("Q#{E}")   # trailer_bytes
  end

  # ---- mask ----

  def test_mask_offsets
    a = CArray.int32(4).seq
    a[2] = UNDEF
    s = CArray.dump(a)
    assert_equal 1, s[16].ord                           # has_mask
    assert_equal HDR + 16, s[184, 8].unpack1("Q#{E}")   # mask_offset
    assert_equal 4,        s[192, 8].unpack1("Q#{E}")   # mask_bytes
  end

  # ---- attributes ----

  def test_attribute_round_trip
    a = CArray.float64(4).seq
    a.set_attr(:units, "m/s")
    a.set_attr(:scale, 2)
    a.set_attr(:tags, ["x", "y"])
    b = CArray.load(CArray.dump(a))
    assert_equal "m/s", b.attr("units")
    assert_equal 2, b.attr("scale")
    assert_equal ["x", "y"], b.attr("tags")
  end

  def test_attribute_non_finite_floats
    a = CArray.float64(3).seq
    a.set_attr(:fillvalue, Float::INFINITY)
    a.set_attr(:neg, -Float::INFINITY)
    a.set_attr(:nan, Float::NAN)
    b = CArray.load(CArray.dump(a))
    assert_equal Float::INFINITY, b.attr("fillvalue")
    assert_equal(-Float::INFINITY, b.attr("neg"))
    assert b.attr("nan").nan?
  end

  def test_trailer_is_single_line_flow
    a = CArray.float64(2).seq
    a.set_attr(:units, "m/s")
    s = CArray.dump(a)
    off = s[200, 8].unpack1("Q#{E}")
    len = s[208, 8].unpack1("Q#{E}")
    trailer = s[off, len]
    refute_includes trailer, "\n"
    assert_match(/\A\{attrs: \{/, trailer)
  end

  def test_has_trailer_flag_set_when_attrs_present
    plain = CArray.dump(CArray.float64(2).seq)
    assert_equal 0, plain[17].ord              # has_trailer clear
    a = CArray.float64(2).seq
    a.set_attr(:units, "m/s")
    withattr = CArray.dump(a)
    assert_equal 1, withattr[17].ord           # has_trailer set
  end

  def test_has_trailer_flag_set_for_data_class
    rc = CARecord.new(Rec, 1)
    rc[0] = Rec.new(:lat => 0.0, :lng => 0.0, :id => 0)
    s = CArray.dump(rc)
    assert_equal 1, s[17].ord                  # has_trailer set for data_class
  end

  def test_flags_snapshot_parses_back_and_is_inert
    a = CArray.float64(2, 3).seq
    src_flags = a.flags
    h = CArray::Serializer.unpack_header(CArray.dump(a), CArray.endian)
    assert_equal src_flags, h[:flags]
    # flags is provenance only: it must not influence the loaded array.
    b = CArray.load(CArray.dump(a))
    assert_equal a, b
    assert_equal CArray, b.class
  end

  def test_hostile_trailer_tag_is_refused_on_load
    # A trailer carrying a !ruby/object: tag must not deserialise into
    # a live Ruby object (Psych.safe_load guardrail).
    a = CArray.float64(2).seq
    a.set_attr(:units, "m/s")
    s = CArray.dump(a).dup
    off = s[200, 8].unpack1("Q#{E}")
    len = s[208, 8].unpack1("Q#{E}")
    poisoned = "{attrs: {t: !ruby/object:Object {}}}"
    # only exercise the decoder guard when the poisoned string fits
    if poisoned.bytesize <= len
      s[off, poisoned.bytesize] = poisoned
      s[off + poisoned.bytesize, len - poisoned.bytesize] = " " * (len - poisoned.bytesize)
      assert_raises(Psych::DisallowedClass) { CArray.load(s) }
    end
  end

  # ---- data_class ----

  Rec = CArray.struct(:pack => 1) { float64 :lat; float64 :lng; int32 :id }

  def test_named_data_class_round_trip
    rc = CARecord.new(Rec, 2)
    rc[0] = Rec.new(:lat => 1.5, :lng => 2.5, :id => 7)
    rc[1] = Rec.new(:lat => 3.5, :lng => 4.5, :id => 8)
    rc2 = CArray.load(CArray.dump(rc))
    assert_equal Rec, rc2.data_class
    assert_equal 1.5, rc2[0][:lat]
    assert_equal 8, rc2[1][:id]
    assert_equal rc, rc2
  end

  def test_data_class_layer1_schema_in_trailer
    rc = CARecord.new(Rec, 1)
    rc[0] = Rec.new(:lat => 0.0, :lng => 0.0, :id => 0)
    s = CArray.dump(rc)
    off = s[200, 8].unpack1("Q#{E}")
    len = s[208, 8].unpack1("Q#{E}")
    schema = Psych.safe_load(s[off, len])["data_class"]
    assert_equal "struct", schema["kind"]
    assert_equal 20, schema["record_bytes"]
    assert_equal Rec.name, schema["name"]
    assert_equal(
      [{ "name" => "lat", "type" => "d", "offset" => 0,  "bytes" => 8 },
       { "name" => "lng", "type" => "d", "offset" => 8,  "bytes" => 8 },
       { "name" => "id",  "type" => "i", "offset" => 16, "bytes" => 4 }],
      schema["members"])
  end

  def test_anonymous_data_class_synthesised_on_load
    # Named at save time, but the constant is gone at load time: the
    # loader falls through to Layer 1 synthesis (duck-typed access,
    # identity not preserved).
    tmp = CArray.struct(:pack => 1) { int16 :a; float32 :b }
    self.class.const_set(:TmpRec, tmp)
    rc = CARecord.new(tmp, 1)
    rc[0] = tmp.new(:a => 5, :b => 1.5)
    s = CArray.dump(rc)
    self.class.send(:remove_const, :TmpRec)
    rc2 = CArray.load(s)
    assert_operator rc2.data_class, :<, CAStruct
    assert_equal 5, rc2[0][:a]
    assert_in_delta 1.5, rc2[0][:b], 1e-6
    assert_equal 6, rc2.data_class::DATA_SIZE
  end

  # ---- endian override ----

  def test_endian_override_round_trip
    a = CArray.int32(4).seq
    be = CArray.dump(a, :endian => CA_BIG_ENDIAN)
    assert_equal 0x01, be[8].ord                      # marker leading byte = BE
    assert_equal MARKER, be[8, 4].unpack1("L>")       # marker in file endian
    assert_equal a, CArray.load(be)
  end

  # ---- CA_OBJECT boundary ----

  def test_object_save_raises
    o = CArray.object(3) { Time.now }
    assert_raises(ArgumentError) { CArray.dump(o) }
    assert_raises(ArgumentError) { CArray.save(o, StringIO.new("".b)) }
  end

  # ---- Marshal path (separated) ----

  def test_marshal_object_round_trip
    o = CArray.object(2, 3) { 3.times { Time.now } }
    o[1, 1] = UNDEF
    o2 = Marshal.load(Marshal.dump(o))
    assert_equal o, o2
    assert o2.has_mask?
  end

  def test_marshal_numeric_round_trip
    a = CArray.int32(3, 3) { 10 }
    a[1, 1] = UNDEF
    a2 = Marshal.load(Marshal.dump(a))
    assert_equal a, a2
    assert a2.has_mask?
  end

  # ---- bad input ----

  def test_bad_magic_raises
    io = StringIO.new(("garbage" + "\x00" * HDR).b)
    assert_raises(RuntimeError) { CArray.load(io) }
  end

  def test_truncated_header_raises
    io = StringIO.new("_CARRAY3\x00\x00".b)
    assert_raises(RuntimeError) { CArray.load(io) }
  end
end

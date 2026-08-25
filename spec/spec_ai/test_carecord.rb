# PROPOSAL_CARECORD.md R.9 — comprehensive test matrix
#
# Covers AC1-AC9, AC12, AC13 from §5 Acceptance criteria.
# AC10 (perf bench) is R.10 scope; AC11 (regression sweep) is run via `rake spec_ai`.
#
# Known gap (not formally pinned here, surfaced during R.9 authoring):
#   - Field projection on derived CARecord views (e.g. `arr[0..1]["lat"]`,
#     `arr.transpose["lat"]`) raises `[BUG] instance variable member doesn't
#     defined for data_class array` because `@member` ivar is only initialised
#     on the CARecord built via `ca_record_build`. Sliced/transposed copies
#     inherit `data_class` but not `@member`. Follow-up R.9.1 / R.10 territory.

require "test/unit"
require "carray"

class TestCARecord < Test::Unit::TestCase

  # ---- Fixture struct ------------------------------------------------------

  GeoCoord = CArray.struct { float64 :lat; float64 :lng } unless defined?(GeoCoord)
  Pixel    = CArray.struct { uint8 :r; uint8 :g; uint8 :b } unless defined?(Pixel)

  # =========================================================================
  # AC1 — CARecord.new(MyStruct, *shape) constructs 1-D / 2-D / N-D arrays
  # =========================================================================

  def test_ac1_construct_1d
    a = CARecord.new(GeoCoord, 5)
    assert_kind_of CARecord, a
    assert_equal [5], a.dim
    assert_equal 5, a.elements
    assert_equal GeoCoord, a.data_class
  end

  def test_ac1_construct_2d
    a = CARecord.new(GeoCoord, 3, 4)
    assert_equal [3, 4], a.dim
    assert_equal 12, a.elements
    assert_equal GeoCoord, a.data_class
  end

  def test_ac1_construct_nd
    a = CARecord.new(GeoCoord, 2, 3, 4)
    assert_equal [2, 3, 4], a.dim
    assert_equal 24, a.elements
  end

  def test_ac1_parent_is_fixlen_entity
    a = CARecord.new(GeoCoord, 5)
    p = a.parent
    assert_kind_of CArray, p
    assert_equal CA_FIXLEN, p.data_type
    assert_equal GeoCoord::DATA_SIZE, p.bytes
    assert_equal 5, p.elements
  end

  def test_ac1_class_hierarchy
    a = CARecord.new(GeoCoord, 3)
    assert_kind_of CARecord, a
    assert_kind_of CAFace, a
    assert_kind_of CAView, a
    assert_kind_of CArray, a
  end

  def test_ac1_face_predicate
    a = CARecord.new(GeoCoord, 3)
    assert_equal true, a.face?
    assert_equal false, a.parent.face?
  end

  def test_ac1_rejects_non_struct_class
    assert_raise(TypeError) { CARecord.new(Integer, 5) }
    assert_raise(TypeError) { CARecord.new(String, 5) }
  end

  # =========================================================================
  # AC2 — Field projection (arr["field"], arr.field(i), arr[i]["field"])
  # =========================================================================

  def test_ac2_string_field_projection
    a = CARecord.new(GeoCoord, 3)
    f = a["lat"]
    assert_kind_of CAField, f
    assert_equal :float64, f.data_type_name rescue assert_equal(CA_FLOAT64, f.data_type)
    assert_equal [3], f.dim
  end

  def test_ac2_field_projects_on_parent
    # R.6: Face strip — field view is on parent, not Face
    a = CARecord.new(GeoCoord, 3)
    f = a["lat"]
    assert_same a.parent, f.parent
  end

  def test_ac2_field_cache_consistency
    a = CARecord.new(GeoCoord, 3)
    f1 = a["lat"]
    f2 = a["lat"]
    assert_same f1, f2
  end

  def test_ac2_integer_field_via_field_method
    a = CARecord.new(GeoCoord, 3)
    f0 = a.field(0)
    assert_kind_of CAField, f0
  end

  def test_ac2_field_write_propagates_to_parent
    a = CARecord.new(GeoCoord, 3)
    a["lat"][] = CArray.float64(3).seq
    a["lng"][] = CArray.float64(3).seq * 10
    # Parent bytes reflect the writes
    bytes = a.parent.dump_binary.unpack("D*")
    assert_equal [0.0, 0.0, 1.0, 10.0, 2.0, 20.0], bytes
  end

  def test_ac2_element_access_returns_struct_instance
    # AC2 / AC12: a[i] -> GeoCoord.decode(parent[i])
    a = CARecord.new(GeoCoord, 3)
    a["lat"][0] = 42.5
    a["lng"][0] = -71.3
    v = a[0]
    assert_kind_of GeoCoord, v
    assert_equal 42.5, v["lat"]
    assert_equal(-71.3, v["lng"])
  end

  def test_ac2_element_access_field_on_decoded_struct
    # arr[i]["field"]  --  decoded GeoCoord supports ["field"] member access
    a = CARecord.new(GeoCoord, 3)
    a["lat"][1] = 7.0
    a["lng"][1] = 8.0
    g = a[1]
    assert_equal 7.0, g["lat"]
    assert_equal 8.0, g["lng"]
  end

  # =========================================================================
  # AC3 — arr.parent byte parity with manually built FIXLEN entity
  # =========================================================================

  def test_ac3_parent_byte_parity_via_dump_round_trip
    a = CARecord.new(GeoCoord, 4)
    a["lat"][] = CArray.float64(4).seq
    a["lng"][] = CArray.float64(4).seq * 100

    # Dump CARecord bytes and load into plain CA_FIXLEN entity of same shape
    bytes = a.dump_binary
    ent = CArray.new(CA_FIXLEN, [4], bytes: GeoCoord::DATA_SIZE)
    ent.load_binary(bytes)

    assert_equal a.parent.dump_binary, ent.dump_binary
    assert_equal a.parent.dump_binary.bytesize, GeoCoord::DATA_SIZE * 4
  end

  def test_ac3_dump_binary_size
    a = CARecord.new(GeoCoord, 3, 4)
    assert_equal GeoCoord::DATA_SIZE * 12, a.dump_binary.bytesize
  end

  # =========================================================================
  # AC4 — subclass DSL (`data_class MyStruct`)
  # =========================================================================

  def test_ac4_subclass_dsl_basic
    klass = Class.new(CARecord) do
      data_class GeoCoord
    end
    arr = klass.new(7)
    assert_kind_of klass, arr
    assert_equal GeoCoord, arr.data_class
    assert_equal [7], arr.dim
  end

  def test_ac4_subclass_dsl_multi_dim
    klass = Class.new(CARecord) do
      data_class GeoCoord
    end
    arr = klass.new(3, 4)
    assert_equal [3, 4], arr.dim
  end

  def test_ac4_subclass_dsl_getter
    klass = Class.new(CARecord) do
      data_class GeoCoord
    end
    assert_equal GeoCoord, klass.data_class
  end

  def test_ac4_subclass_dsl_immutable
    klass = Class.new(CARecord) do
      data_class GeoCoord
    end
    assert_raise(RuntimeError) do
      klass.instance_eval { data_class Pixel }
    end
  end

  def test_ac4_subclass_dsl_rejects_non_struct
    assert_raise(TypeError) do
      Class.new(CARecord) do
        data_class String
      end
    end
  end

  def test_ac4_subclass_dsl_then_new_with_data_class_double_specs
    klass = Class.new(CARecord) do
      data_class GeoCoord
    end
    # Passing data_class again to .new on a DSL-fixed subclass is an error
    assert_raise(ArgumentError) { klass.new(GeoCoord, 5) }
  end

  # =========================================================================
  # AC5 — subclass array-level method (= residence for operator definition)
  # =========================================================================

  def test_ac5_subclass_instance_method
    klass = Class.new(CARecord) do
      data_class GeoCoord
      def total_lat
        self["lat"].sum
      end
    end
    arr = klass.new(5)
    arr["lat"][] = 1.0
    assert_in_delta 5.0, arr.total_lat, 1e-9
  end

  def test_ac5_subclass_method_with_args
    klass = Class.new(CARecord) do
      data_class GeoCoord
      def scale_lat(k)
        self["lat"][] = self["lat"] * k
        self
      end
    end
    arr = klass.new(3)
    arr["lat"][] = CArray.float64(3).seq + 1.0
    arr.scale_lat(10.0)
    assert_equal [10.0, 20.0, 30.0], arr["lat"].to_a
  end

  # =========================================================================
  # AC6 — Mask carry
  # =========================================================================

  def test_ac6_mask_initially_absent
    a = CARecord.new(GeoCoord, 5)
    assert_equal false, a.has_mask?
  end

  def test_ac6_mask_set_propagates
    a = CARecord.new(GeoCoord, 5)
    a["lat"][] = CArray.float64(5).seq
    a.mask = 0
    a[2] = UNDEF
    assert_equal true, a.has_mask?
    assert_equal 1, a.count_masked
    assert_equal [false, false, true, false, false], a.mask.to_a
  end

  def test_ac6_masked_element_reads_as_undef
    a = CARecord.new(GeoCoord, 4)
    a["lat"][] = CArray.float64(4).seq
    a.mask = 0
    a[1] = UNDEF
    assert_equal UNDEF, a[1]
  end

  def test_ac6_field_view_inherits_mask
    a = CARecord.new(GeoCoord, 5)
    a["lat"][] = CArray.float64(5).seq
    a.mask = 0
    a[2] = UNDEF
    f = a["lat"]
    assert_equal true, f.has_mask?
    assert_equal 1, f.count_masked
  end

  def test_ac6_strip_mask_with_encoded_fill
    a = CARecord.new(GeoCoord, 3)
    a["lat"][] = CArray.float64(3).seq
    a.mask = 0
    a[1] = UNDEF
    fill = GeoCoord.new(lat: 99.0, lng: 88.0).encode
    sm = a.strip_mask(fill)
    assert_kind_of CARecord, sm
    assert_equal false, sm.has_mask?
    assert_in_delta 99.0, sm[1]["lat"], 1e-9
    assert_in_delta 88.0, sm[1]["lng"], 1e-9
  end

  # =========================================================================
  # AC7 — data_class accessor returns CAStruct subclass (via tail Face dispatch)
  # =========================================================================

  def test_ac7_data_class_accessor_from_record
    a = CARecord.new(GeoCoord, 3)
    assert_equal GeoCoord, a.data_class
  end

  def test_ac7_data_class_distinct_for_different_records
    a = CARecord.new(GeoCoord, 3)
    b = CARecord.new(Pixel, 3)
    assert_equal GeoCoord, a.data_class
    assert_equal Pixel, b.data_class
  end

  def test_ac7_parent_has_no_data_class
    # Face strip: data_class lives on Face, not parent
    a = CARecord.new(GeoCoord, 3)
    assert_nil a.parent.data_class
  end

  # =========================================================================
  # AC8 — CArray.new(MyStruct, [N]) raises ArgumentError (3.0 breaking)
  # =========================================================================

  def test_ac8_carray_new_with_struct_class_raises
    err = assert_raise(ArgumentError) { CArray.new(GeoCoord, [5]) }
    assert_match(/CARecord/, err.message)
  end

  def test_ac8_carray_new_with_pixel_class_raises
    assert_raise(ArgumentError) { CArray.new(Pixel, [3]) }
  end

  # =========================================================================
  # AC9 — file I/O round-trip (dump_binary / load_binary, both directions)
  # =========================================================================

  def test_ac9_dump_and_load_carecord_round_trip
    a = CARecord.new(GeoCoord, 5)
    a["lat"][] = CArray.float64(5).seq
    a["lng"][] = CArray.float64(5).seq * 10

    bytes = a.dump_binary

    b = CARecord.new(GeoCoord, 5)
    b.load_binary(bytes)

    assert_equal a["lat"].to_a, b["lat"].to_a
    assert_equal a["lng"].to_a, b["lng"].to_a
  end

  def test_ac9_carecord_to_fixlen_entity_byte_parity
    a = CARecord.new(GeoCoord, 4)
    a["lat"][] = CArray.float64(4).seq * 1.5
    a["lng"][] = CArray.float64(4).seq * 2.5

    bytes = a.dump_binary

    ent = CArray.new(CA_FIXLEN, [4], bytes: GeoCoord::DATA_SIZE)
    ent.load_binary(bytes)

    assert_equal a.parent.dump_binary, ent.dump_binary
  end

  def test_ac9_round_trip_via_wrap
    a = CARecord.new(GeoCoord, 3)
    a["lat"][] = [1.0, 2.0, 3.0].to_ca
    a["lng"][] = [10.0, 20.0, 30.0].to_ca

    bytes = a.dump_binary
    ent = CArray.new(CA_FIXLEN, [3], bytes: GeoCoord::DATA_SIZE)
    ent.load_binary(bytes)

    w = CARecord.wrap(ent, GeoCoord)
    assert_equal a["lat"].to_a, w["lat"].to_a
    assert_equal a["lng"].to_a, w["lng"].to_a
  end

  # =========================================================================
  # AC12 — fetch_method path → GeoCoord.decode(bytes) fires
  # =========================================================================

  def test_ac12_element_access_returns_struct_via_decode
    a = CARecord.new(GeoCoord, 3)
    a["lat"][0] = 3.14
    a["lng"][0] = 2.71
    v = a[0]
    assert_kind_of GeoCoord, v
    assert_in_delta 3.14, v["lat"], 1e-9
    assert_in_delta 2.71, v["lng"], 1e-9
  end

  def test_ac12_element_assign_round_trip
    a = CARecord.new(GeoCoord, 3)
    g = GeoCoord.new(lat: 11.0, lng: 22.0)
    a[1] = g
    decoded = a[1]
    assert_equal 11.0, decoded["lat"]
    assert_equal 22.0, decoded["lng"]
  end

  def test_ac12_each_yields_struct_instances
    a = CARecord.new(GeoCoord, 3)
    a["lat"][] = CArray.float64(3).seq
    a["lng"][] = CArray.float64(3).seq * 10
    seen = []
    a.each { |v| seen << v }
    assert_equal 3, seen.length
    assert seen.all? { |v| v.kind_of?(GeoCoord) }
    assert_equal [0.0, 1.0, 2.0], seen.map { |v| v["lat"] }
  end

  # =========================================================================
  # AC13 — CARecord.wrap zero-copy parity
  # =========================================================================

  def test_ac13_wrap_returns_carecord
    ent = CArray.new(CA_FIXLEN, [5], bytes: GeoCoord::DATA_SIZE)
    w = CARecord.wrap(ent, GeoCoord)
    assert_kind_of CARecord, w
    assert_equal GeoCoord, w.data_class
    assert_equal [5], w.dim
  end

  def test_ac13_wrap_parent_aliases_entity
    ent = CArray.new(CA_FIXLEN, [5], bytes: GeoCoord::DATA_SIZE)
    w = CARecord.wrap(ent, GeoCoord)
    assert_same ent, w.parent
  end

  def test_ac13_wrap_zero_copy_via_field_write
    # Writes via wrapped CARecord propagate to the original entity bytes,
    # since parent is alias.
    ent = CArray.new(CA_FIXLEN, [3], bytes: GeoCoord::DATA_SIZE)
    w = CARecord.wrap(ent, GeoCoord)
    w["lat"][] = [1.0, 2.0, 3.0].to_ca
    w["lng"][] = [10.0, 20.0, 30.0].to_ca
    # Inspect entity bytes
    assert_equal [1.0, 10.0, 2.0, 20.0, 3.0, 30.0],
                 ent.dump_binary.unpack("D*")
  end

  def test_ac13_wrap_rejects_non_fixlen_parent
    assert_raise(TypeError, ArgumentError, RuntimeError) do
      CARecord.wrap(CArray.float64(5), GeoCoord)
    end
  end

  def test_ac13_wrap_rejects_non_struct_data_class
    ent = CArray.new(CA_FIXLEN, [5], bytes: GeoCoord::DATA_SIZE)
    assert_raise(TypeError) { CARecord.wrap(ent, String) }
  end

  # =========================================================================
  # R.9.1 — chain field projection on derived CARecord views
  # =========================================================================
  # rb_ca_face_field lazy-inits @member when nil, so derived views
  # (sliced / transposed / subclass-derived) can project fields.

  def test_chain_slice_field_projection
    a = CARecord.new(GeoCoord, 5)
    a["lat"][] = CArray.float64(5).seq
    sl = a[1..3]
    assert_kind_of CARecord, sl
    assert_equal GeoCoord, sl.data_class
    f = sl["lat"]
    assert_kind_of CAField, f
    assert_equal [1.0, 2.0, 3.0], f.to_a
  end

  def test_chain_transpose_field_projection
    a = CARecord.new(GeoCoord, 2, 3)
    a["lat"][] = CArray.float64(2, 3).seq
    tr = a.transpose
    assert_equal [3, 2], tr.dim
    f = tr["lat"]
    assert_kind_of CAField, f
    assert_equal [3, 2], f.dim
    # Transpose of seq(2,3) [[0,1,2],[3,4,5]] -> [[0,3],[1,4],[2,5]]
    assert_equal [[0.0, 3.0], [1.0, 4.0], [2.0, 5.0]], f.to_a
  end

  def test_chain_subclass_slice_field_projection
    klass = Class.new(CARecord) do
      data_class GeoCoord
    end
    arr = klass.new(5)
    arr["lat"][] = CArray.float64(5).seq
    sl = arr[1..3]
    assert_equal [1.0, 2.0, 3.0], sl["lat"].to_a
  end

  def test_chain_derived_view_member_cache_local
    # @member on the derived view is independent of the original CARecord
    a = CARecord.new(GeoCoord, 5)
    a["lat"][] = CArray.float64(5).seq
    sl = a[1..3]
    f1 = sl["lat"]
    f2 = sl["lat"]
    assert_same f1, f2
  end

  # =========================================================================
  # Auxiliary — reflection / structural properties
  # =========================================================================

  def test_aux_fields_returns_caf_ield_array
    a = CARecord.new(GeoCoord, 3)
    flds = a.fields
    assert_kind_of Array, flds
    assert_equal 2, flds.length
    assert flds.all? { |f| f.kind_of?(CAField) }
  end

  def test_aux_subclass_face_predicate
    klass = Class.new(CARecord) do
      data_class GeoCoord
    end
    arr = klass.new(3)
    assert_equal true, arr.face?
  end

  def test_aux_pixel_struct_works
    # Sanity: a different fixture struct also works end-to-end.
    a = CARecord.new(Pixel, 4)
    assert_equal Pixel, a.data_class
    assert_equal Pixel::DATA_SIZE, a.parent.bytes
    a["r"][] = CArray.uint8(4) { |i| [10, 20, 30, 40][i] }
    a["g"][] = CArray.uint8(4) { |i| [11, 21, 31, 41][i] }
    a["b"][] = CArray.uint8(4) { |i| [12, 22, 32, 42][i] }
    v = a[2]
    assert_kind_of Pixel, v
    assert_equal 30, v["r"]
    assert_equal 31, v["g"]
    assert_equal 32, v["b"]
  end

end

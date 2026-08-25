require "test/unit"
require "carray"

# ENHANCE_CASTRUCT Phase A.3+ (carray-3.0):
# Column-level access to bit-typed struct members:
#
#     records["flag"]          #=> CABitfield view of the column
#     records["flag"][i]       # per-record bit read
#     records["flag"][i] = 1   # per-record bit write, propagates
#     records["flag"][nil] = 1 # bulk write across all records
#
# Before this phase, accessing a bit member via `records["..."]`
# raised "<\"bitfield\"> is unknown data_type representation" because
# rb_ca_field_as_member naively forwarded the MEMBER_TABLE tuple to
# CArray#field, which doesn't know `:bitfield`.  We now detect the
# `:bitfield` type-marker, project the spanning bytes to a power-of-2
# uint{8,16,32,64} CAField, and call #bitfield(range) on that.
#
# This mirrors the per-record dispatch in CAStruct#[] / #[]=, which
# in Step 3 routes through CAStruct::DISPATCH_TABLE's bit dispatcher
# (CAStruct::Builder.build_bitfield_dispatcher).

class TestCAStructBitfieldColumn < Test::Unit::TestCase

  def make_struct
    CArray.struct(pack: 1) {
      uint16 :header
      bit :flag_a,  bits: 1
      bit :flag_b,  bits: 1
      bit :version, bits: 6     # together with the two flags: 1 byte
      uint32 :payload           # starts at byte 3
    }
  end

  def populate (s)
    rs = CARecord.new(s, 4)
    rs[0] = s.new(header: 0x1000, flag_a: 1, flag_b: 0, version: 10, payload: 0xAAAA0000)
    rs[1] = s.new(header: 0x2000, flag_a: 0, flag_b: 1, version: 20, payload: 0xBBBB0000)
    rs[2] = s.new(header: 0x3000, flag_a: 1, flag_b: 1, version: 30, payload: 0xCCCC0000)
    rs[3] = s.new(header: 0x4000, flag_a: 0, flag_b: 0, version: 40, payload: 0xDDDD0000)
    rs
  end

  # ----------------------------------------------------------------
  # Read
  # ----------------------------------------------------------------

  def test_one_bit_column_returns_cabitfield_view
    s  = make_struct
    rs = populate(s)
    col = rs["flag_a"]
    assert_kind_of CArray, col
    assert_equal "CABitfield", col.class.name
    assert_equal [4],          col.dim
    assert_equal [true, false, true, false], col.to_a
  end

  def test_two_independent_bit_columns
    s  = make_struct
    rs = populate(s)
    assert_equal [true, false, true, false], rs["flag_a"].to_a
    assert_equal [false, true, true, false], rs["flag_b"].to_a
  end

  def test_multibit_column
    s  = make_struct
    rs = populate(s)
    assert_equal [10, 20, 30, 40], rs["version"].to_a
  end

  def test_bit_column_reflection_matches_per_record_reads
    s  = make_struct
    rs = populate(s)
    col = rs["version"]
    4.times do |i|
      assert_equal rs[i].version, col[i]
    end
  end

  def test_byte_column_still_works_alongside_bit_columns
    # Sanity: introducing bit-aware routing must not break the
    # plain CAField path for byte-typed members.
    s  = make_struct
    rs = populate(s)
    assert_equal [0x1000, 0x2000, 0x3000, 0x4000], rs["header"].to_a
    assert_equal [0xAAAA0000, 0xBBBB0000, 0xCCCC0000, 0xDDDD0000],
                 rs["payload"].to_a
  end

  # ----------------------------------------------------------------
  # Write
  # ----------------------------------------------------------------

  def test_per_record_bit_write_propagates
    s  = make_struct
    rs = populate(s)
    rs["flag_a"][1] = 1
    assert_equal 1, rs[1].flag_a
    # Other bits in the same packed byte must be untouched.
    assert_equal 1, rs[1].flag_b
    assert_equal 20, rs[1].version
    # Neighbouring byte-typed members untouched.
    assert_equal 0x2000, rs[1].header
    assert_equal 0xBBBB0000, rs[1].payload
  end

  def test_bulk_bit_column_write_to_scalar
    s  = make_struct
    rs = populate(s)
    rs["flag_a"][nil] = 1
    4.times { |i| assert_equal 1, rs[i].flag_a }
    # flag_b/version/header/payload should all be unchanged
    assert_equal [false, true, true, false],            rs["flag_b"].to_a
    assert_equal [10, 20, 30, 40],        rs["version"].to_a
    assert_equal [0x1000, 0x2000, 0x3000, 0x4000], rs["header"].to_a
  end

  def test_bulk_multibit_column_write
    s  = make_struct
    rs = populate(s)
    rs["version"][nil] = 7
    4.times { |i| assert_equal 7, rs[i].version }
    # flag_a/flag_b unchanged
    assert_equal [true, false, true, false], rs["flag_a"].to_a
    assert_equal [false, true, true, false], rs["flag_b"].to_a
  end

  def test_array_assignment_to_bit_column
    s  = make_struct
    rs = populate(s)
    rs["version"][nil] = CArray.uint8(4).tap { |__a| __a[] = [1, 2, 3, 63] }
    assert_equal [1, 2, 3, 63], rs["version"].to_a
  end

  # ----------------------------------------------------------------
  # Multi-byte bit field (8 bits crossing a byte boundary)
  # ----------------------------------------------------------------

  def test_8bit_field_crossing_byte_boundary
    # 4-bit pad + 8-bit field → field spans 4 bits of byte 0 and 4
    # bits of byte 1.  Routing must pick the 2-byte uint16 projection.
    s = CArray.struct(pack: 1) {
      bit :pad,   bits: 4
      bit :value, bits: 8
    }
    rs = CARecord.new(s, 3)
    rs[0] = s.new(pad: 0xA, value: 0xCD)
    rs[1] = s.new(pad: 0x5, value: 0x77)
    rs[2] = s.new(pad: 0x0, value: 0xFF)
    assert_equal [0xCD, 0x77, 0xFF], rs["value"].to_a
    rs["value"][1] = 0x12
    assert_equal 0x12, rs[1].value
    assert_equal 0x5,  rs[1].pad  # pad untouched
  end

  # ----------------------------------------------------------------
  # Caching
  # ----------------------------------------------------------------

  def test_column_view_is_cached_per_name
    # rb_ca_field_as_member memoises views in the @member hash so
    # callers can rely on identity (same Ruby object on second
    # lookup) and writes to one alias are visible on the next read.
    s  = make_struct
    rs = populate(s)
    col1 = rs["flag_a"]
    col2 = rs["flag_a"]
    assert_same col1, col2
  end

  # ----------------------------------------------------------------
  # Multi-dim records
  # ----------------------------------------------------------------

  def test_multidim_records_bit_column_shape_matches
    s  = make_struct
    rs = CARecord.new(s, 2, 3)
    6.times do |k|
      i, j = k.divmod(3)
      rs[i, j] = s.new(header: 0, flag_a: k % 2, flag_b: 0,
                       version: k, payload: 0)
    end
    col = rs["flag_a"]
    assert_equal [2, 3], col.dim
    assert_equal [[false, true, false], [true, false, true]], col.to_a
  end

end

require "test/unit"
require "carray"
require "fiddle"

# A record array's MemoryView format is written in Ruby's vocabulary
# (ruby/memory_view.h): the members' specifiers in their order in the
# record, "x<N>" for padding, and byte order as Ruby writes it.  Ruby's
# format has no member names; the record array gives them as
# #memory_view_field_names, one per specifier.

class TestMVStructFormat < Test::Unit::TestCase

  PARSE = Fiddle::Function.new(Fiddle::Handle::DEFAULT["rb_memory_view_parse_item_format"],
                               [Fiddle::TYPE_VOIDP] * 4, Fiddle::TYPE_SSIZE_T)

  # [item size, number of items] as Ruby's own parser reads the format
  def ruby_parse (format)
    members = Fiddle::Pointer.malloc(8)
    count   = Fiddle::Pointer.malloc(8)
    err     = Fiddle::Pointer.malloc(8)
    err[0, 8] = "\0" * 8
    [PARSE.call(format, members, count, err), count[0, 8].unpack1("Q")]
  end

  def format_of (struct, n = 1)
    CArray.__memory_view_format__(CARecord.new(struct, n))
  end

  # --- core emission ----------------------------------------------------

  def test_members_in_order
    s = CArray.struct(pack: 1) { float64 :y; int32 :x; int8 :z }
    assert_equal "dic", format_of(s)
    assert_equal [13, 3], ruby_parse(format_of(s))
  end

  def test_primitive_types_in_ruby_vocabulary
    s = CArray.struct(pack: 1) {
      int8 :a; uint8 :b; int16 :c; uint16 :d; int32 :e; uint32 :f
      int64 :g; uint64 :h; float32 :i; float64 :j
    }
    assert_equal "cCsSiIqQfd", format_of(s)
    assert_equal [s::DATA_SIZE, 10], ruby_parse(format_of(s))
  end

  def test_types_ruby_cannot_spell_stay_as_at_the_top_level
    s = CArray.struct(pack: 1) { boolean :p; cmplx64 :z; cmplx128 :w }
    assert_equal "?ZfZd", format_of(s)
  end

  # --- padding ---------------------------------------------------------

  def test_padding_between_and_after_members
    s = CArray.struct { uint8 :a; uint64 :b }             # aligned
    assert_equal "Cx7Q", format_of(s)
    assert_equal [16, 2], ruby_parse(format_of(s))
    t = CArray.struct(pack: 1, size: 16) { uint32 :x }
    assert_equal "Ix12", format_of(t)
    assert_equal [16, 1], ruby_parse(format_of(t))
  end

  # --- byte order --------------------------------------------------------

  def test_declared_byte_order_as_ruby_writes_it
    s = CArray.struct(pack: 1) {
      int32 :i, endian: :big; int16 :h, endian: :little
      float32 :f, endian: :big; float64 :d, endian: :little
      uint8 :u, endian: :big; int32 :n
    }
    assert_equal "i>s<gECi", format_of(s)
    assert_equal [s::DATA_SIZE, 6], ruby_parse(format_of(s))
  end

  def test_complex_with_declared_byte_order_is_refused
    s = CArray.struct(pack: 1) { cmplx64 :z, endian: :big }
    a = CARecord.new(s, 1)
    refute CArray.memory_view_available?(a)
    assert_nil a.memory_view_field_names
  end

  # --- member names --------------------------------------------------------

  def test_field_names_one_per_specifier
    s = CArray.struct { uint8 :a; uint64 :b }
    a = CARecord.new(s, 2)
    assert_equal %w[a b], a.memory_view_field_names
    assert_equal %w[a b], a[0..0].memory_view_field_names
  end

  # --- refused ---------------------------------------------------------------

  def test_records_the_format_cannot_describe_are_refused
    [CArray.struct(pack: 1) { uint8 :flag; bit :b, bits: 1 },
     CArray.struct(pack: 1) { int32 :a; fixlen :opaque, bytes: 8 },
     CArray.union { int32 :a; float32 :b }].each do |s|
      a = CARecord.new(s, 1)
      refute CArray.memory_view_available?(a), s.inspect
      assert_nil CArray.__memory_view_format__(a)
      assert_nil a.memory_view_field_names
    end
  end

  def test_struct_array_is_memory_view_available
    s = CArray.struct(pack: 1) { int32 :a; float64 :b }
    a = CARecord.new(s, 4)
    assert CArray.memory_view_available?(a)
    assert_nil CArray.memory_view_reject_reason(a)
    assert_equal 12, Fiddle::MemoryView.new(a).item_size
  end

  def test_bare_fixlen_without_data_class_emits_ns
    a = CArray.new(:fixlen, [3], bytes: 4)
    assert CArray.memory_view_available?(a)
    assert_equal "4s", CArray.__memory_view_format__(a)
  end

  # --- caching -----------------------------------------------------------------

  def test_format_string_is_cached_and_frozen
    s = CArray.struct(pack: 1) { int32 :a; float64 :b }
    a = CARecord.new(s, 1)
    assert_same CArray.__memory_view_format__(a), CArray.__memory_view_format__(a)
    assert_predicate CArray.__memory_view_format__(a), :frozen?
  end

  # --- top level -----------------------------------------------------------------

  def test_top_level_and_field_views
    assert_equal "i", CArray.__memory_view_format__(CArray.int32(3))
    assert_equal "?", CArray.__memory_view_format__(CArray.boolean(3))
    s = CArray.struct(pack: 1) { int32 :id; float64 :x }
    assert_equal "d", CArray.__memory_view_format__(CARecord.new(s, 5)["x"])
  end

end

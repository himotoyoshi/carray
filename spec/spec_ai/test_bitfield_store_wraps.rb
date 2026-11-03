# frozen_string_literal: true
#
# A value stored into a bit field keeps its low bits (modulo 2 ** bits),
# whether it is written through a struct element, the member's column view,
# a view over that column, or CArray#bitfield.  A String is read as a
# decimal number on every one of these paths.

require "test/unit"
require "carray"

class TestBitfieldStoreWraps < Test::Unit::TestCase
  S = CArray.struct { bit :w, bits: 64; bit :f, bits: 3; bit :h, bits: 12; float64 :x; int16 :i }

  VALUES = [-1, 7, 8, 200, 300, 5000, -4097, 2**70 + 3, 2.5, "3", "300", "-1"]

  def wrap(v, bits)
    i = v.is_a?(String) ? Integer(v, 10) : Integer(v)
    i % (2**bits)
  end

  def test_element_and_column_agree_and_wrap
    { "f" => 3, "h" => 12, "w" => 64 }.each do |m, bits|
      VALUES.each do |v|
        e = S.new
        e[m] = v
        r = CARecord.new(S, 2)
        r[m][0] = v
        assert_equal wrap(v, bits), e[m], "element #{m} = #{v.inspect}"
        assert_equal wrap(v, bits), r[m][0], "column #{m} = #{v.inspect}"
      end
    end
  end

  def test_every_store_path_of_a_column_wraps
    r = CARecord.new(S, 3)
    r["f"][] = [-1, 300, 9]
    assert_equal [7, 4, 1], r["f"].to_a
    r["f"][] = %w[-2 301 10]
    assert_equal [6, 5, 2], r["f"].to_a
    r["f"].fill(-1)
    assert_equal [7, 7, 7], r["f"].to_a
    r["f"][] = 300
    assert_equal [4, 4, 4], r["f"].to_a
    r["f"][CA_INT64([0, 2])] = -2
    assert_equal [6, 4, 6], r["f"].to_a
    r["f"][r["f"].eq(6)] = -3
    assert_equal [5, 4, 5], r["f"].to_a
    r["f"][1..2] = -1
    assert_equal [5, 7, 7], r["f"].to_a
    r["f"].elem_store(0, 9)
    assert_equal [1, 7, 7], r["f"].to_a
  end

  def test_signed_bitfield_wraps_into_its_range
    a = CA_UINT8([0])
    b = a.bitfield(0..2, :int8)
    [[-1, -1], [4, -4], [-5, 3], [200, 0], [7, -1]].each do |v, want|
      b[0] = v
      assert_equal want, b[0], v.inspect
      assert_equal want % 8, a[0], v.inspect
    end
  end

  def test_other_members_and_plain_arrays_still_refuse
    e = S.new
    r = CARecord.new(S, 1)
    assert_raise(RangeError) { e.i = 2**20 }
    assert_raise(RangeError) { r["i"][0] = 2**20 }
    assert_raise(RangeError) { CA_UINT8([0])[0] = 300 }
    assert_raise(RangeError) { CA_UINT8([0])[] = [300] }
    assert_raise(ArgumentError) { e.f = "1.5" }
    assert_raise(ArgumentError) { r["f"][0] = "1.5" }
  end

  def test_a_string_member_value_is_read_as_a_decimal
    e = S.new
    r = CARecord.new(S, 1)
    e.x = "1.5"
    r["x"][0] = "1.5"
    assert_equal 1.5, e.x
    assert_equal 1.5, r["x"][0]
    e.i = "-7"
    assert_equal(-7, e.i)
    assert_raise(ArgumentError) { e.i = "1.5" }
    assert_raise(ArgumentError) { r["i"][0] = "1.5" }
  end

  def test_an_endian_member_reads_a_string
    big = [1].pack("s") == [1].pack("s>") ? :little : :big
    t = CArray.struct { int16 :a, endian: big; float64 :b, endian: big }
    e = t.new
    e.a = "-300"
    e.b = "2.25"
    assert_equal(-300, e.a)
    assert_equal 2.25, e.b
  end

  def test_a_float_array_keeps_its_integer_part_modulo_the_bits
    r = CARecord.new(CArray.struct { bit :f, bits: 3; int16 :i }, 4)
    r["f"][] = CA_FLOAT64([2.5, -1.0, 9, 300])
    assert_equal [2, 7, 1, 4], r["f"].to_a
    r["f"][] = CA_FLOAT32([1.9, -2.0, 15, 0])
    assert_equal [1, 6, 7, 0], r["f"].to_a
    assert_raise(FloatDomainError) { r["f"][] = CA_FLOAT64([Float::NAN, 0, 0, 0]) }
    a = CA_UINT8([0])
    assert_raise(RangeError) { a[] = CA_FLOAT64([-1.0]) }
  end

  def test_a_stack_or_meld_of_fields_keeps_the_low_bits
    f = CARecord.new(CArray.struct { bit :f, bits: 3; int16 :i }, 4)["f"]
    CArray.stack([f, f])[0, 0] = 300
    assert_equal 4, f[0]
    CArray.stack([f, f]).fill(13)
    assert_equal [5, 5, 5, 5], f.to_a
    CArray.meld(f, f).fill(-1)
    assert_equal [7, 7, 7, 7], f.to_a
    CArray.meld(f, f)[] = CA_OBJECT([300] * 8)
    assert_equal [4, 4, 4, 4], f.to_a
    g = CARecord.new(CArray.struct { bit :g, bits: 4; int16 :i }, 4)["g"]
    assert_raise(RangeError) { CArray.stack([f, g])[0, 0] = 300 }
    a = CA_UINT8([0])
    assert_raise(RangeError) { CArray.stack([a, a])[0, 0] = 300 }
  end
end

require "test/unit"
require "carray"

# A Face is compared as the values it holds: `==` is true for two Faces of
# the same class holding the same values at the same places, whatever their
# unit, pool or vocabulary, and never for a Face and an array that is not
# one.  `eql?` is the Hash key relation, so it also asks for the same state
# and the same storage.

class TestFaceEquality < Test::Unit::TestCase

  def ts
    CArray.time(%w[2024-01-01T00:00:00 2024-01-02T00:00:00], unit: :s)
  end

  def cat (codes, labels)
    CACategorical.from_codes(CA_UINT8(codes), labels)
  end

  def test_equal_values_are_equal_across_unit_pool_and_vocabulary
    {
      "time in s and ms"       => [ts, ts.to_unit(:ms)],
      "const strings, 2 pools" => [CArray.const_string(%w[ab cd]),
                                   CArray.const_string(%w[zz ab cd])[1..2]],
      "categorical, 2 orders"  => [cat([0, 1], %w[a b]), cat([1, 0], %w[b a])],
    }.each do |name, (a, b)|
      assert a == b, "#{name}: =="
      assert b == a, "#{name}: == (reversed)"
      assert !a.eql?(b), "#{name}: eql? asks for the same state"
    end
  end

  def test_different_values_or_kinds_are_not_equal
    td = CArray.int64(2) { |i| [1704067200, 1704153600][i] }.timedelta(unit: :s)
    {
      "time and timedelta, same ticks" => [ts, td],
      "time and its bytes"             => [ts, ts.parent.copy.refer(:fixlen, [2], bytes: 8)],
      "time and its storage"           => [ts, ts.parent],
      "string and object strings"      => [CArray.string(%w[ab cd]), CA_OBJECT(%w[ab cd])],
      "categorical, other values"      => [cat([0, 1], %w[a b]), cat([0, 0], %w[b a])],
      "time, one instant moved"        => [ts, CArray.time(%w[2024-01-01T00:00:00 2024-01-02T00:00:01], unit: :ms)],
    }.each do |name, (a, b)|
      assert !(a == b), "#{name}: =="
      assert !(b == a), "#{name}: == (reversed)"
      assert !a.eql?(b), "#{name}: eql?"
    end
  end

  def test_the_same_kind_in_the_same_state_is_equal_and_the_same_key
    a = ts
    b = ts
    b[1] = UNDEF
    c = b.copy
    assert a == ts && a.eql?(ts) && a.hash == ts.hash
    assert b == c && b.eql?(c)
    assert !(a == b)
  end
end

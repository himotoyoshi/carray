# A method that matches the values of two arrays settles one type for both:
# CArray.result_type, widened by value_match_type where that type cannot hold
# every value of both (a mixed-sign pair, a wide integer beside float32).
# Neither side is cast to the other's type.  So for every pair of numeric
# types the answer equals the one given after casting both sides to that
# type first.

require "test/unit"
require "carray"

class TestValueSetResultType < Test::Unit::TestCase

  TYPES = %i[int8 uint8 int16 uint16 int32 uint32 int64 uint64
             float32 float64]

  # Values that one type of a pair would truncate or wrap: 1.5 against an
  # integer type, -1 and 300 against unsigned or 8-bit types.
  VALUES = [0, 1, 1.5, -1, 2, 300, 7]

  def build (type, values)
    values = values.select { |v|
      t = CArray.send(type, 1)
      begin
        t[0] = v
        t[0] == v
      rescue RangeError
        false
      end
    }
    CArray.send(type, values.size) { values }
  end

  def common (a, b)
    t = a.send(:value_match_type, CArray.result_type(a, b), b.data_type)
    [a.to_type(t), b.to_type(t)]
  end

  def each_pair
    TYPES.each do |ta|
      TYPES.each do |tb|
        a = build(ta, VALUES)
        b = build(tb, VALUES.reverse)
        next if a.elements == 0 || b.elements == 0
        yield "#{ta} x #{tb}", a, b
      end
    end
  end

  def test_is_in
    each_pair do |name, a, b|
      ca, cb = common(a, b)
      assert_equal ca.is_in(cb).to_a, a.is_in(b).to_a, name
    end
  end

  def test_set_operations
    each_pair do |name, a, b|
      ca, cb = common(a, b)
      %i[intersection difference union].each do |op|
        assert_equal ca.send(op, cb, sort: true).to_a,
                     a.send(op, b, sort: true).to_a, "#{op} #{name}"
      end
    end
  end

  def test_locate_addr
    each_pair do |name, a, b|
      ca, cb = common(a, b)
      assert_equal ca.locate_addr(cb).to_a, a.locate_addr(b).to_a, name
    end
  end

end

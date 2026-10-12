require "test/unit"
require "carray"

# Every family that takes an operand against a Face (comparison, search,
# count, the value-hash family, linear_section) brings the operand into the
# Face's storage space by one rule, so a pair of arrays is either taken by
# all of them or refused by all of them:
#
#   - a COMPARABLE Face takes a plain operand or a COMPARABLE Face;
#   - a Face with to_comparable brings any operand into its own space;
#   - any other Face refuses the operand.
#
# The value-hash family first reads a string or categorical operand by its
# values, and promotes a plain operand in Ruby, so for those operands only
# the families that take the operand as it is are checked here.

class TestFaceOperandReconcile < Test::Unit::TestCase

  # ORDERABLE, not COMPARABLE, no to_comparable.
  class OrderedTicks < CAObject
    def initialize (parent)
      super(CA_FIXLEN, parent.dim, bytes: 8, storage: CA_INT64, parent: parent,
            face: true, orderable_storage: true)
    end
    def storage_to_element (raw)
      raw.is_a?(String) ? raw.unpack1("q") : raw
    end
  end

  # ORDERABLE and COMPARABLE.
  class PlainTicks < CAObject
    def initialize (parent)
      super(CA_FIXLEN, parent.dim, bytes: 8, storage: CA_INT64, parent: parent,
            face: true, orderable_storage: true, comparable_storage: true)
    end
    def storage_to_element (raw)
      raw.is_a?(String) ? raw.unpack1("q") : raw
    end
  end

  TAKEN_AS_IT_IS = {
    "eq"           => ->(r, o) { r.eq(o) },
    "<"            => ->(r, o) { r < o },
    "search"       => ->(r, o) { r.search(o) },
    "count"        => ->(r, o) { r.count(o) },
  }

  FAMILIES = TAKEN_AS_IT_IS.merge(
    "is_in"        => ->(r, o) { r.is_in(o) },
    "intersection" => ->(r, o) { r.intersection(o) },
  )

  def time (*s)
    CArray.time(s, unit: :D)
  end

  def refused (receiver, operand, families = FAMILIES)
    families.each do |name, op|
      assert_raise(ArgumentError, "#{name}: #{receiver.class} / #{operand.class}") {
        op.call(receiver, operand)
      }
    end
  end

  def test_comparable_face_refuses_a_face_whose_storage_encodes_its_values
    plain = PlainTicks.new(CA_INT64([3, 1]))
    refused(plain, time("2024-01-01", "2024-01-02"))
    refused(plain, OrderedTicks.new(CA_INT64([3, 1])))
    refused(plain, CArray.const_string(["a", "b"]), TAKEN_AS_IT_IS)
    refused(plain, CArray.string(["a", "b"]).categorize, TAKEN_AS_IT_IS)
  end

  def test_fixlen_string_refuses_a_face_whose_storage_encodes_its_values
    s = CArray.fixlen_string(["aa", "bb"], bytes: 8)
    refused(s, time("2024-01-01", "2024-01-02"))
    refused(s, CArray.const_string(["aa", "bb"]), TAKEN_AS_IT_IS)
  end

  def test_face_without_a_way_to_read_the_operand_refuses_everything
    ticks = OrderedTicks.new(CA_INT64([3, 1]))
    refused(ticks, PlainTicks.new(CA_INT64([3, 1])))
    refused(ticks, CA_INT64([3, 1]), TAKEN_AS_IT_IS)
    refused(ticks, 2, TAKEN_AS_IT_IS)
  end

  def test_comparable_face_takes_plain_operands_and_its_own_kind
    plain = PlainTicks.new(CA_INT64([3, 1]))
    [CA_INT64([3, 9]), PlainTicks.new(CA_INT64([3, 9]))].each do |operand|
      assert_equal [true, false], plain.eq(operand).to_a
      assert_equal 0, plain.search(operand)[0]
      assert_equal [1, 0], plain.count(operand).to_a
    end
    assert_equal [true, false], plain.is_in(PlainTicks.new(CA_INT64([3, 9]))).to_a
  end

  def test_time_takes_a_single_value_as_a_set_of_one
    t = time("2024-01-01", "2024-01-02", "2024-01-03")
    [Time.utc(2024, 1, 2), CArray.time(["2024-01-02"], unit: :h)[0]].each do |v|
      assert_equal [false, true, false], t.is_in(v).to_a
      assert_equal ["2024-01-02"], t.intersection(v).to_a.map(&:to_s)
    end
    assert_raise(TypeError) { t.is_in(2) }
  end

  def test_record_names_both_data_classes
    p_ = CArray.struct { int32 :x }
    q_ = CArray.struct { int32 :y }
    a = CARecord.new(p_, 2)
    b = CARecord.new(q_, 2)
    FAMILIES.slice("eq", "count", "is_in").each do |name, op|
      e = assert_raise(TypeError, name) { op.call(a, b) }
      assert_match(/record array of #{q_}.* record array of #{p_}/, e.message)
    end
  end
end

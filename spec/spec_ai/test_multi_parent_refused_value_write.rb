# spec_ai/test_multi_parent_refused_value_write.rb
#
# A stack or meld of parts of different data types writes each part through
# a cast, which refuses a value its part's type can not hold.  The write
# goes to the parts one after another, so a refusal from a later part must
# not leave the parts before it written -- whatever the order the write
# reaches them in, also through a view that hands the write on in pieces.

require "test/unit"
require "carray"

class TestMultiParentRefusedValueWrite < Test::Unit::TestCase

  def float_part
    CArray.float64(3).seq(1)
  end

  BUILDS = {
    "stack"           => ->(a, b) { CArray.stack([a, b]) },
    "stack, reversed" => ->(a, b) { CArray.stack([b, a]) },
    "meld"            => ->(a, b) { CArray.meld(a, b) },
    "meld, reversed"  => ->(a, b) { CArray.meld(b, a) },
  }

  VIEWS = {
    "itself"         => ->(s) { s },
    "index array"    => ->(s) { s.ndim == 2 ? s[CA_INT([1, 0]), nil] : s[CA_INT([5, 4, 3, 2, 1, 0])] },
    "transpose"      => ->(s) { s.ndim == 2 ? s.transpose : s },
    "boolean select" => ->(s) { s[s.template(:boolean) { 1 }] },
  }

  WRITES = {
    "store"   => ->(v) { v[] = 1000 },
    "fill"    => ->(v) { v.fill(1000) },
    "map!"    => ->(v) { v.map! { 1000 } },
    "add!"    => ->(v) { v.add!(1000) },
    "array"   => ->(v) { v[] = v.template(:float64) { 1000 } },
  }

  def test_a_refused_write_changes_no_part
    BUILDS.each do |bname, build|
      VIEWS.each do |vname, view|
        WRITES.each do |wname, write|
          a = float_part
          b = CArray.int8(3).seq
          v = view.call(build.call(a, b))
          name = "#{bname} / #{vname} / #{wname}"
          assert_raise(RangeError, name) { write.call(v) }
          assert_equal [1.0, 2.0, 3.0], a.to_a, name
          assert_equal [0, 1, 2], b.to_a, name
        end
      end
    end
  end

  def test_a_boolean_part_refuses_a_number
    a = float_part
    s = CArray.stack([a, CArray.boolean(3)])
    assert_raise(CArray::DataTypeError) { s[] = 7 }
    assert_equal [1.0, 2.0, 3.0], a.to_a
  end

  def test_a_write_every_part_can_hold_lands_in_every_part
    a = float_part
    b = CArray.int8(3).seq
    s = CArray.stack([a, b])
    s[CA_INT([1, 0]), nil] = CA_FLOAT64([[7, 8, 9], [1.5, 2.5, 3.5]])
    assert_equal [1.5, 2.5, 3.5], a.to_a
    assert_equal [7, 8, 9], b.to_a
    s.add!(1)
    assert_equal [2.5, 3.5, 4.5], a.to_a
    assert_equal [8, 9, 10], b.to_a
  end
end

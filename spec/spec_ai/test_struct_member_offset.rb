require "test/unit"
require "carray"

# offset: places a member where it says, or is refused; it is never
# dropped in favour of another position.
class TestStructMemberOffset < Test::Unit::TestCase

  Inner = CArray.struct(pack: 1) { int16 :a }

  def test_nested_struct_member_at_its_offset
    o = CArray.struct(pack: 1, size: 4) { int8 :z; struct :n, type: Inner, offset: 2 }
    assert_equal [["z", 0], ["n", 2]], o.fields.map { |f| [f.name, f.offset] }
    v = o.new(z: 1, n: Inner.new(a: 300))
    assert_equal [1, 300], [v[:z], v[:n][:a]]
  end

  def test_array_member_at_its_offset
    o = CArray.struct(pack: 1, size: 16) { int8 :z; array :v, type: CArray.int32(3), offset: 4 }
    assert_equal 4, o.fields.find { |f| f.name == "v" }.offset
  end

  def test_offset_in_an_aligned_struct_is_refused
    assert_raise(CAStruct::DefinitionError) { CArray.struct { int8 :a; int32 :x, offset: 1 } }
  end

  def test_union_member_offset_other_than_zero_is_refused
    assert_raise(CAStruct::DefinitionError) { CArray.union { int8 :a, offset: 4; float64 :b } }
    assert_equal 8, CArray.union { int8 :a, offset: 0; float64 :b }::DATA_SIZE
  end
end

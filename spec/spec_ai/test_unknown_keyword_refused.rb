require "test/unit"
require "carray"

# A misspelt keyword is refused, not ignored.  These are the places that read
# their options one key at a time (or took a keyword Hash as an operand), so
# a typo used to change the answer without a word.
class TestUnknownKeywordRefused < Test::Unit::TestCase

  def setup
    @i = CA_INT32([0x01020304])
    @f = CArray.float64(3, 4).seq!
  end

  def test_dump_save_load
    assert_raise(ArgumentError) { CArray.dump(@i, endain: :big) }
    assert_raise(ArgumentError) { CArray.load(CArray.dump(@i), data_tyep: :int32) }
    assert_equal [1, 2, 3, 4], CArray.dump(@i, endian: :big).byteslice(8, 4).bytes
    assert_equal @i.to_a, CArray.load(CArray.dump(@i, endian: :big)).to_a
  end

  def test_result_type
    assert_equal :int32, CArray.result_type(@i, @i)
    assert_raise(ArgumentError) { CArray.result_type(@i, @i, zzz: 1) }
  end

  def test_struct_options
    assert_equal 5, CArray.struct(pack: 1) { int8 :a; int32 :b }.size
    assert_raise(ArgumentError) { CArray.struct(pakc: 1) { int8 :a; int32 :b } }
    assert_raise(ArgumentError) { CArray.union(pakc: 1) { int8 :a } }
  end

  def test_struct_member_options
    assert_equal 8, CArray.struct(pack: 1) { int8 :a; int32 :b, offset: 4 }.size
    assert_raise(ArgumentError) { CArray.struct(pack: 1) { int8 :a; int32 :b, offst: 4 } }
    assert_raise(ArgumentError) { CArray.struct { int32 :b, endain: :big } }
    assert_raise(ArgumentError) { CArray.struct { array :x, type: CArray.int8(2), offst: 1 } }
    assert_raise(ArgumentError) { CArray.struct { struct(:s, pakc: 1) { int8 :x } } }
    assert_equal 2, CArray.struct(pack: 1) { int8 :a; struct(:s, offset: 1) { int8 :x } }.size
  end

  def test_clone_of_wrap_and_remap
    r = @f.sort(axis: 1)
    assert_true r.clone(freeze: true).frozen?
    assert_raise(ArgumentError) { r.clone(frezee: true) }
    w = CArray.wrap_memory_view(@f)
    assert_true w.clone(freeze: true).frozen?
    assert_raise(ArgumentError) { w.clone(zzz: 1) }
  end

  def test_inherit_mask_takes_carrays_only
    assert_kind_of CArray, @f.copy.inherit_mask(@f)
    assert_raise(TypeError) { @f.copy.inherit_mask(@f, 5) }
    assert_raise(ArgumentError) { @f.copy.inherit_mask(@f, zzz: 1) }
    assert_raise(TypeError) { @f.copy.inherit_mask_replace("x") }
  end

  def test_count_with_empty_query_checks_options
    assert_equal [4, 0], @f.count(CA_FLOAT64([]), axis: 0, min_count: 2).shape
    assert_raise(ArgumentError) { @f.count(CA_FLOAT64([]), axis: 0, min_cont: 2) }
  end

end

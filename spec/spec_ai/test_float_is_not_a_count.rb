require "test/unit"
require "carray"

# A shape, a size or a count is an Integer.  A Float is refused, whole or not,
# rather than cut down to one.  Keys of `[]` are the exception: there a Float
# with no fraction is a position (see test_index_key_rule and its neighbours).
class TestFloatIsNotACount < Test::Unit::TestCase

  A = CArray.int32(6).seq.freeze

  COUNTS = {
    "CArray.new"          => ->(x) { CArray.new(:int32, [x]) },
    "CArray.new, axis 1"  => ->(x) { CArray.new(:int32, [2, x]) },
    "CArray.int32"        => ->(x) { CArray.int32(x) },
    "CArray.float64"      => ->(x) { CArray.float64(x, 2) },
    "CArray.object"       => ->(x) { CArray.object(x) },
    "CArray::Int32.new"   => ->(x) { CArray::Int32.new(x) },
    "CArray.fixlen"       => ->(x) { CArray.fixlen(x, bytes: 2) },
    "bytes:"              => ->(x) { CArray.fixlen(2, bytes: x) },
    "CArray.new bytes:"   => ->(x) { CArray.new(:fixlen, [2], bytes: x) },
    "as_type bytes:"      => ->(x) { A.as_type(:fixlen, bytes: x) },
    "linspace"            => ->(x) { CArray.linspace(0, 1, x) },
    "eye"                 => ->(x) { CArray.eye(x) },
    "identity"            => ->(x) { CArray.identity(x) },
    "reshape"             => ->(x) { A.reshape(x, 3) },
    "reshape, inferred"   => ->(x) { A.reshape(x, -1) },
    "refer"               => ->(x) { A.refer(:int32, [x]) },
    "refer offset"        => ->(x) { A.refer(:int32, [2], offset: x) },
    "broadcast_to"        => ->(x) { CArray.int32(1).broadcast_to(x) },
    "each_index"          => ->(x) { CArray.each_index(x) { } },
    "window range"        => ->(x) { A.window(0..x) },
    "bitfield range"      => ->(x) { A.bitfield(0..x) },
    "blocks"              => ->(x) { A.blocks(x) },
    "blocks range"        => ->(x) { A.blocks(0..x) },
    "CAFrame#head"        => ->(x) { CAFrame.new({ "a" => A }).head(x) },
    "CAFrame#tail"        => ->(x) { CAFrame.new({ "a" => A }).tail(x) },
  }.freeze

  COUNTS.each { |name, call|
    define_method("test_#{name.gsub(/\W+/, "_")}_refuses_a_float") {
      assert_raise(TypeError, "2.0") { call[2.0] }
      assert_raise(TypeError, "2.5") { call[2.5] }
      call[2]
    }
  }

  def test_shapes_of_the_address_helpers
    assert_raise(TypeError) { CArray.addr2index(1, shape: [2.5]) }
    assert_raise(TypeError) { CArray.index2addr(1, shape: [2.5]) }
  end

  def test_an_endless_block_range_is_refused_by_name
    e = assert_raise(TypeError) { A.blocks(2..) }
    assert_match(/blocks/, e.message)
  end
end

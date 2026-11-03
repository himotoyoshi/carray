require "test/unit"
require "carray"

# A record comes back through MemoryView as raw bytes of the record's size:
# the format has no member names to rebuild it from.
class TestMemoryViewRecordAsBytes < Test::Unit::TestCase

  def record
    s = CArray.struct(pack: 1) { int32 :a; float64 :b }
    r = CARecord.new(s, 3)
    r["a"][] = CArray.int32(3).seq(1)
    r["b"][] = CArray.float64(3).seq(1.5)
    r
  end

  def test_from_memory_view_copies_the_bytes
    r = record
    x = CArray.from_memory_view(r)
    assert_equal [:fixlen, 12, [3]], [x.data_type, x.bytes, x.shape]
    assert_equal [1, 1.5].pack("ld"), [x[0]].pack("a12")
    x[0] = "\0" * 12
    assert_equal [1, 2, 3], r["a"].to_a
  end

  def test_wrap_memory_view_shares_the_bytes
    r = record
    x = CArray.wrap_memory_view(r)
    assert_equal [:fixlen, 12, [3]], [x.data_type, x.bytes, x.shape]
    x[0] = "\0" * 12
    assert_equal [0, 2, 3], r["a"].to_a
  end

end

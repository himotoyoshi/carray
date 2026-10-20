# A boolean cell holds 0 or 1.  Every way bytes get into a boolean array
# from outside keeps it so: a copy (load_binary, CArray.load, Marshal, a
# MemoryView copy) reads a non-zero byte as true, and a view that would
# read another type's bytes as boolean (refer, field) is refused.  A byte
# of 2 used to read as true in to_a, as 2 in to_type(:int32) and sum, and
# as neither true nor false in count.

require "test/unit"
require "carray"
require "stringio"
require "tmpdir"

class TestBooleanBytes < Test::Unit::TestCase

  def assert_one_answer (a, expected)
    assert_equal expected, a.to_a
    assert_equal expected.map { |v| v ? 1 : 0 }, a.to_type(:int32).to_a
    assert_equal expected.count(true), a.count(true)
    assert_equal expected.count(false), a.count(false)
    assert_equal expected.count(true), a.sum
    assert_equal expected.count(true), a.copy.to_type(:uint8).sum
  end

  def test_load_binary_from_a_string
    assert_one_answer CArray.boolean(3).load_binary("\x02\x00\xff".b), [true, false, true]
  end

  def test_load_binary_from_an_io
    assert_one_answer CArray.boolean(3).load_binary(StringIO.new("\x02\x00\xff".b)),
                      [true, false, true]
  end

  def test_load_binary_into_a_view
    b = CArray.boolean(4)
    b[[0, 2, 2]].load_binary("\x02\x07".b)
    assert_one_answer b, [true, false, true, false]
  end

  def test_file_and_marshal
    b = CArray.boolean(3) { 1 }
    path = File.join(Dir.tmpdir, "boolean_bytes_#{Process.pid}.ca")
    CArray.save(b, path)
    data = File.binread(path)
    data[data.index("\x01\x01\x01".b), 1] = "\x02".b
    File.binwrite(path, data)
    assert_one_answer CArray.load(path), [true, true, true]
    s = Marshal.dump(b)
    s[s.index("\x01\x01\x01".b), 1] = "\x02".b
    assert_one_answer Marshal.load(s), [true, true, true]
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def test_a_mask_read_in_is_0_or_1
    b = CArray.float64(3) { 1.0 }
    b[1] = UNDEF
    path = File.join(Dir.tmpdir, "boolean_mask_bytes_#{Process.pid}.ca")
    CArray.save(b, path)
    data = File.binread(path)
    data[data.rindex("\x00\x01\x00".b) + 1, 1] = "\x05".b
    File.binwrite(path, data)
    c = CArray.load(path)
    assert_equal [0, 1, 0], c.mask.to_type(:int32).to_a
    assert_equal 1, c.count_masked
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  # A "?" producer with a byte of 2: the copy reads it as true, the wrap
  # (which shares it) refuses.
  def test_memory_view
    $LOAD_PATH.unshift(File.expand_path("ext_memory_view_test", __dir__))
    begin
      require "mv_borrower"
    rescue LoadError
      omit "mv_borrower fixture not built"
    end
    m = MVBorrower::Crafted.new("\x02\x00".b, format: "?", item_size: 1, shape: [2])
    assert_one_answer CArray.from_memory_view(m), [true, false]
    assert_raise(ArgumentError) { CArray.wrap_memory_view(m) }
  end

  def test_views_of_other_bytes_are_refused
    u = CArray.uint8(2) { |i| [2, 0][i] }
    assert_raise(CArray::DataTypeError) { u.refer(:boolean) }
    assert_raise(CArray::DataTypeError) { u.field(0, :boolean) }
    assert_raise(CArray::DataTypeError) { CArray.int32(2).refer(:boolean, [8]) }
    # a boolean array refers to itself as boolean, as a mask does
    assert_equal [true, false], CArray.boolean(2) { |i| 1 - i }.refer(:boolean).to_a
    assert_equal [2, 0], u.ne(0).to_type(:int32).to_a.map { |x| x * 2 }
  end
  # A record's boolean member is a byte that other fields can write as any
  # byte; it is read through a cast to boolean, which refuses one that is
  # not 0 or 1, rather than answering differently in each method.
  def test_a_boolean_member_refuses_a_byte_that_is_not_0_or_1
    r = CArray.fixlen(4, bytes: 1)
    r.field(0, :uint8)[] = [2, 255, 0, 1]
    b = r.field(0, :boolean)
    assert_raise(RangeError) { b.to_a }
    assert_raise(RangeError) { b.count(true) }
    r.field(0, :uint8)[] = [1, 0, 0, 1]
    assert_equal [true, false, false, true], b.to_a
    b[1] = true
    assert_equal [1, 1, 0, 1], r.field(0, :uint8).to_a
    st = CArray.struct { boolean :b; int8 :x }
    rec = CARecord.new(st, 3)
    rec["b"][] = [true, false, true]
    assert_equal [true, false, true], rec["b"].to_a
    assert_equal true, rec[0].b
  end

end

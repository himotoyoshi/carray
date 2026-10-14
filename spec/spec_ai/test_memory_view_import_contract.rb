require "test/unit"
require "open3"
require "carray"

# What from_memory_view / wrap_memory_view promise about producers that
# misstate their geometry, typeless producers, borrowed masks, the format
# vocabulary and the receiver class.  The producers come from
# MVBorrower::Crafted, which reports whatever the test tells it to.

borrower_dir = File.expand_path("ext_memory_view_test", __dir__)
$LOAD_PATH.unshift(borrower_dir)
begin
  require "mv_borrower"
rescue LoadError
  warn "Skipping test_memory_view_import_contract: mv_borrower.bundle not built."
  return
end

class TestMemoryViewImportContract < Test::Unit::TestCase

  P = MVBorrower::Crafted
  BORROWER_DIR = File.expand_path("ext_memory_view_test", __dir__)
  ROOT = File.expand_path("../..", __dir__)

  def i32 (*vals)
    vals.pack("l*")
  end

  def released? (prod)
    prod.gets == prod.releases
  end

  # Cases that crashed the process before the fix run in a child, so a
  # regression fails the test instead of ending the run.
  def run_isolated (code)
    script = <<~RUBY
      require "carray"
      require "mv_borrower"
      P = MVBorrower::Crafted
      #{code}
    RUBY
    out, err, st = Open3.capture3(RbConfig.ruby,
                                  "-I", File.join(ROOT, "ext"),
                                  "-I", File.join(ROOT, "lib"),
                                  "-I", BORROWER_DIR,
                                  "-e", script)
    [st.success?, out, err]
  end

  # ---------- geometry checked against the buffer ----------

  def test_wrap_refuses_a_shape_larger_than_the_buffer
    pr = P.new(i32(*0...16), format: "l", item_size: 4, shape: [65536])
    assert_raise(ArgumentError) { CArray.wrap_memory_view(pr) }
    assert released?(pr)
  end

  def test_from_refuses_a_shape_larger_than_the_buffer_with_argument_error
    pr = P.new(i32(*0...16), format: "l", item_size: 4, shape: [65536])
    assert_raise(ArgumentError) { CArray.from_memory_view(pr) }
    assert released?(pr)
  end

  def test_mask_shorter_than_its_shape_is_refused
    d = P.new(i32(*0...4096), format: "l", item_size: 4, shape: [4096])
    m = P.new("\0" * 64, format: "?", item_size: 1, shape: [4096])
    assert_raise(ArgumentError) { CArray.wrap_memory_view(d, mask: m) }
    assert_raise(ArgumentError) { CArray.from_memory_view(d, mask: m) }
    assert released?(d)
    assert released?(m)
  end

  def test_strided_view_whose_byte_size_is_short_of_its_shape_is_refused
    pr = P.new(i32(*0...8), format: "l", item_size: 4, shape: [4], strides: [8],
               byte_size: 8)
    assert_raise(ArgumentError) { CArray.wrap_memory_view(pr) }
    assert_raise(ArgumentError) { CArray.from_memory_view(pr) }
  end

  def test_negative_shape_is_refused_and_released
    pr = P.new(i32(1, 2), format: "l", item_size: 4, shape: [-2])
    assert_raise(ArgumentError) { CArray.from_memory_view(pr) }
    assert_raise(ArgumentError) { CArray.wrap_memory_view(pr) }
    assert released?(pr)
  end

  def test_overflowing_shape_is_refused_and_released
    pr = P.new(i32(1), format: "l", item_size: 4,
               shape: [2**40, 2**40], strides: [0, 0])
    assert_raise(ArgumentError) { CArray.from_memory_view(pr) }
    assert_raise(ArgumentError) { CArray.wrap_memory_view(pr) }
    assert released?(pr)
  end

  def test_mask_failure_releases_both_views
    d = P.new(i32(1, 2, 3), format: "l", item_size: 4, shape: [3])
    m = P.new("\0\0", format: "?", item_size: 1, shape: [-2])
    assert_raise(ArgumentError) { CArray.wrap_memory_view(d, mask: m) }
    assert_raise(ArgumentError) { CArray.from_memory_view(d, mask: m) }
    assert released?(d)
    assert released?(m)
  end

  # ---------- strides omitted ----------

  def test_strides_omitted_reads_as_row_major
    ok, out, err = run_isolated(<<~RUBY)
      pr = P.new([1,2,3,4,5,6].pack("l*"), format: "l", item_size: 4,
                 shape: [2, 3], strides_null: true)
      p CArray.from_memory_view(pr).to_a
      p CArray.wrap_memory_view(pr).to_a
      q = P.new([7,8,9].pack("l*"), format: "l", item_size: 4,
                shape: [3], strides_null: true)
      p CArray.from_memory_view(q).to_a
    RUBY
    assert ok, err
    assert_equal "[[1, 2, 3], [4, 5, 6]]\n[[1, 2, 3], [4, 5, 6]]\n[7, 8, 9]\n", out
  end

  def test_mask_with_strides_omitted
    ok, out, err = run_isolated(<<~RUBY)
      d = P.new([1,2,3].pack("l*"), format: "l", item_size: 4, shape: [3])
      m = P.new("\\0\\1\\0", format: "?", item_size: 1, shape: [3], strides_null: true)
      p CArray.wrap_memory_view(d, mask: m).to_a
    RUBY
    assert ok, err
    assert_equal "[1, UNDEF, 3]\n", out
  end

  # ---------- a mask on a strided wrap ----------

  def test_mask_on_a_strided_wrap_lands_on_the_view
    ok, out, err = run_isolated(<<~RUBY)
      n = 64
      pw = P.new((0...n*n).to_a.pack("l*"), format: "l", item_size: 4,
                 shape: [n, n], strides: [4, 4*n], readonly: false)
      rw = CArray.wrap_memory_view(pw)
      rw.mask = 0
      rw[1, 2] = UNDEF
      p [rw.count_masked, rw.is_masked[1, 2], rw.value[3, 5], rw.copy.count_masked]
    RUBY
    assert ok, err
    assert_equal "[1, true, #{5 * 64 + 3}, 1]\n", out
  end

  def test_mask_on_a_strided_wrap_with_odd_strides
    ok, out, err = run_isolated(<<~RUBY)
      bytes = (0...24).to_a.pack("C*")
      pw = P.new(bytes, format: "s", item_size: 2, shape: [3, 2],
                 strides: [7, 3], readonly: false)
      rw = CArray.wrap_memory_view(pw)
      rw[2, 1] = UNDEF
      p [rw.count_masked, rw.is_masked.to_a.flatten.count(true)]
    RUBY
    assert ok, err
    assert_equal "[1, 1]\n", out
  end

  # ---------- boolean bytes are 0 or 1 ----------

  def test_from_normalises_boolean_data
    pr = P.new([0, 1, 2, 255].pack("C*"), format: "?", item_size: 1)
    a = CArray.from_memory_view(pr)
    assert_equal [false, true, true, true], a.to_a
    assert_equal 3, a.count(true)
    assert_equal [0, 1, 1, 1], a.to_type(:int32).to_a
  end

  def test_wrap_refuses_boolean_data_other_than_0_and_1
    pr = P.new([0, 1, 2].pack("C*"), format: "?", item_size: 1)
    assert_raise(ArgumentError) { CArray.wrap_memory_view(pr) }
    assert released?(pr)
    ok = P.new([0, 1, 1].pack("C*"), format: "?", item_size: 1)
    assert_equal [false, true, true], CArray.wrap_memory_view(ok).to_a
  end

  def test_wrap_refuses_a_mask_other_than_0_and_1
    d = P.new(i32(1, 2, 3, 4), format: "l", item_size: 4)
    m = P.new([0, 2, 1, 0].pack("C*"), format: "C", item_size: 1)
    assert_raise(ArgumentError) { CArray.wrap_memory_view(d, mask: m) }
    assert released?(d)
    assert released?(m)
    f = CArray.from_memory_view(d, mask: m)
    assert_equal 2, f.count_masked
    assert_equal 2, f.is_masked.count(true)
  end

  # ---------- read-only mask, overlapping buffers ----------

  def test_wrap_with_a_read_only_mask_is_read_only
    d = P.new(i32(0, 0, 0), format: "l", item_size: 4, readonly: false)
    m = P.new("\0\0\0", format: "?", item_size: 1)
    w = CArray.wrap_memory_view(d, mask: m)
    assert w.read_only?
    assert_raise(RuntimeError) { w[2] = 5 }
  end

  def test_wrap_refuses_a_mask_that_overlaps_the_data
    pr = P.new("\0\0\0", format: "C", item_size: 1, readonly: false)
    assert_raise(ArgumentError) { CArray.wrap_memory_view(pr, mask: pr) }
    assert released?(pr)
    assert_equal [0, 0, 0], CArray.from_memory_view(pr, mask: pr).value.to_a
  end

  # ---------- typeless producers ----------

  def test_typeless_strided_producer_is_refused
    pr = P.new(i32(1, 2, 3, 4), format: nil, item_size: 4, shape: [2], strides: [8])
    assert_raise(ArgumentError) { CArray.from_memory_view(pr, data_type: :int32) }
    assert_raise(ArgumentError) { CArray.wrap_memory_view(pr, data_type: :int32) }
    assert released?(pr)
  end

  def test_wrap_readonly_and_writable_take_the_type_for_a_typeless_producer
    pr = P.new(i32(1, 2, 3), format: nil, item_size: 1)
    assert_equal [1, 2, 3], CArray.wrap_readonly(pr, CA_INT32).to_a
    pw = P.new(i32(1, 2, 3), format: nil, item_size: 1, readonly: false)
    w = CArray.wrap_writable(pw, CA_INT32)
    w[1] = 20
    assert_equal [1, 20, 3], pw.bytes.unpack("l*")
  end

  def test_wrap_writable_asks_for_a_writable_view
    pr = P.new(i32(1, 2, 3), format: "l", item_size: 4, readonly: false,
               refuse_writable: true)
    assert_raise(RuntimeError) { CArray.wrap_writable(pr) }
    assert released?(pr)
  end

  # ---------- zero-dimensional ----------

  def test_zero_dimensional_data_and_mask
    d = P.new(i32(7), format: "l", item_size: 4, shape: [])
    m = P.new("\1", format: "?", item_size: 1, shape: [])
    w = CArray.wrap_memory_view(d, mask: m)
    assert_equal [1], w.shape
    assert_equal 1, w.count_masked
  end

  # ---------- format vocabulary ----------

  def parse (fmt, size)
    CArray.__memory_view_parse_format__(fmt, size)
  end

  def test_ruby_vocabulary_in_host_order
    host = CArray.endian == CA_LITTLE_ENDIAN ? "<" : ">"
    other = host == "<" ? ">" : "<"
    assert_equal :int32,  parse("i#{host}", 4)
    assert_equal :int16,  parse("s!#{host}", 2)
    assert_equal :int64,  parse("q#{host}", 8)
    assert_equal :int16,  parse("s_", 2)
    assert_equal :int64,  parse("j", 8)
    assert_equal :uint64, parse("J", 8)
    assert_nil            parse("i#{other}", 4)
    if host == "<"
      assert_equal :float32, parse("e", 4)
      assert_equal :float64, parse("E", 8)
      assert_equal :uint16,  parse("v", 2)
      assert_equal :uint32,  parse("V", 4)
      assert_nil             parse("g", 4)
      assert_nil             parse("n", 2)
    end
  end

  def test_byte_order_on_one_byte_types_and_native_prefix
    assert_equal :int8,    parse(">c", 1)
    assert_equal :boolean, parse(">?", 1)
    assert_equal :uint8,   parse(">B", 1)
    assert_equal :int8,    parse("c>", 1)
    assert_equal :int32,   parse("@i", 4)
  end

  def test_mask_format_is_read_whole
    d = P.new(i32(1, 2), format: "l", item_size: 4)
    m = P.new("\0\0", format: "C3", item_size: 1)
    assert_raise(ArgumentError) { CArray.wrap_memory_view(d, mask: m) }
    ok = P.new("\0\1", format: "@?", item_size: 1)
    assert_equal [1, UNDEF], CArray.wrap_memory_view(d, mask: ok).to_a
  end

  # ---------- receiver ----------

  def test_from_refuses_a_receiver_it_cannot_return
    pr = P.new(i32(1, 2), format: "l", item_size: 4)
    assert_raise(TypeError) { CScalar.from_memory_view(pr) }
    assert_raise(TypeError) { CATime.from_memory_view(pr) }
    assert_equal [1, 2], CArray.from_memory_view(pr).to_a
    assert_equal [1, 2], CArray::Int32.from_memory_view(pr).to_a
  end

  def test_type_class_forwarders_take_a_mask
    d = P.new(i32(1, 2), format: "l", item_size: 4)
    m = P.new("\0\1", format: "?", item_size: 1)
    assert_equal [1, UNDEF], CArray::Int32.wrap_memory_view(d, mask: m).to_a
    assert_equal [1, UNDEF], CArray::Int32.from_memory_view(d, mask: m).to_a
  end

  # ---------- diagnostic ----------

  def test_reject_reason_is_nil_for_an_object_that_is_not_a_carray
    pr = P.new(i32(1), format: "l", item_size: 4)
    assert_nil CArray.memory_view_reject_reason(pr)
    assert_nil CArray.memory_view_reject_reason(Object.new)
  end

end

require "test/unit"
require "open3"
require "carray"

# What the MemoryView export and a wrap of a borrowed buffer promise
# beyond the import itself:
# - a record array exports from any Ractor;
# - the private read-only lift leaves a borrowed mask read-only;
# - Marshal carries a wrap as a copy, as it does a view of one;
# - the reason given for an object array names its type.

borrower_dir = File.expand_path("ext_memory_view_test", __dir__)
$LOAD_PATH.unshift(borrower_dir)
begin
  require "mv_borrower"
rescue LoadError
  warn "Skipping test_memory_view_wrap_and_export: mv_borrower not built."
  return
end

class TestMemoryViewWrapAndExport < Test::Unit::TestCase

  P = MVBorrower::Crafted
  ROOT = File.expand_path("../..", __dir__)

  # ---------- a record array in another Ractor ----------

  def test_a_record_array_exports_from_another_ractor
    script = <<~RUBY
      require "carray"
      Warning[:experimental] = false
      T = CArray.struct { int16 :a; int32 :b }
      v = Ractor.new(T) { |t|
        r = CARecord.new(t, 3)
        [CArray.memory_view_available?(r),
         CArray.memory_view_reject_reason(r)]
      }.take
      p v
    RUBY
    out, err, st = Open3.capture3(RbConfig.ruby, "-I", File.join(ROOT, "ext"),
                                  "-I", File.join(ROOT, "lib"), "-e", script)
    assert st.success?, err
    assert_equal "[true, nil]", out.strip
  end

  # ---------- the read-only lift and a borrowed mask ----------

  def wrap_with_mask (readonly_mask:)
    d = P.new((0...12).to_a.pack("l*"), format: "i", item_size: 4,
              shape: [3, 4], readonly: false)
    m = P.new([0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0].pack("C*"), format: "?",
              item_size: 1, shape: [3, 4], readonly: readonly_mask)
    [CArray.wrap_memory_view(d, mask: m), d, m]
  end

  def test_the_lift_leaves_a_read_only_borrowed_mask_read_only
    w, _d, m = wrap_with_mask(readonly_mask: true)
    before = m.bytes
    assert_raise(RuntimeError) { w.send(:without_read_only_flag) { w.mask = 0 } }
    assert_raise(RuntimeError) { w.send(:without_read_only_flag) { w[0, 1] = 5 } }
    assert_equal before, m.bytes
    assert w.read_only?
  end

  def test_the_lift_still_writes_a_writable_borrowed_mask
    w, _d, m = wrap_with_mask(readonly_mask: false)
    w.mask = 0
    assert_equal [0] * 12, m.bytes.unpack("C*")
  end

  # ---------- Marshal ----------

  def test_marshal_carries_a_wrap_as_a_copy
    src = CArray.int32(3, 4).seq
    w = CArray.wrap_memory_view(src)
    x = Marshal.load(Marshal.dump(w))
    assert_equal CArray, x.class
    assert_equal src.to_a, x.to_a
    x[0, 0] = 99
    assert_equal 0, src[0, 0]
    assert_equal src[nil, 1].to_a, Marshal.load(Marshal.dump(w[nil, 1])).to_a
  end

  def test_marshal_carries_a_masked_wrap
    w, = wrap_with_mask(readonly_mask: false)
    x = Marshal.load(Marshal.dump(w))
    assert_equal w.to_a, x.to_a
    assert_equal w.is_masked.to_a, x.is_masked.to_a
  end

  # ---------- the reason given for an object array ----------

  def test_the_reason_for_an_object_array_names_the_type
    r = CArray.memory_view_reject_reason(CArray.object(3))
    assert_match(/object/, r)
    refute_match(/\(16\)|CA_FIXLEN|CA_OBJECT/, r)
  end

end

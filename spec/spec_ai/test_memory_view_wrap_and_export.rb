require "test/unit"
require "open3"
require "carray"

# What the MemoryView export and a wrap of a borrowed buffer promise
# beyond the import itself:
# - a record array exports from any Ractor;
# - the private read-only lift leaves a borrowed mask read-only.

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

end

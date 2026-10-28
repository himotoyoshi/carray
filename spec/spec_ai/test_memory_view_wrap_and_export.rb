require "test/unit"
require "open3"
require "carray"

# What the MemoryView export and a wrap of a borrowed buffer promise
# beyond the import itself:
# - a record array exports from any Ractor.

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

end

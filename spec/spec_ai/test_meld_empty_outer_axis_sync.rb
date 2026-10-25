# spec_ai/test_meld_empty_outer_axis_sync.rb
#
# A meld along axis 1 of parents whose axis 0 has length 0 has no cells.
# Writing through it (add!, map!, a store, a fill) syncs the view's own
# buffer back to its parents; that sync moves nothing.  An overrun here does
# not show in a plain run, so the writes run once more in a child process
# under Guard Malloc (macOS), which stops at the first byte outside a block.

require "test/unit"
require "carray"
require "rbconfig"
require "open3"

class TestMeldEmptyOuterAxisSync < Test::Unit::TestCase

  SCRIPT = <<~'RUBY'
    a = CArray.float64(0, 6)
    b = CArray.float64(0, 3)
    [[a, a], [a, b], [b, a, b]].each do |ps|
      m = CArray.meld(*ps, axis: 1)
      m.add!(1)
      m.map! { |x| x }
      m[] = 5.0
      m.fill(2.0)
      m.seq!
      raise "shape" unless m.shape == [0, ps.sum { |p| p.shape[1] }]
    end
    o = CArray.object(0, 2)
    m = CArray.meld(o, o, axis: 1)
    m.add!(1)
    m[] = :x
    puts "ok"
  RUBY

  def test_writes_through_an_empty_meld
    eval(SCRIPT)
    a = CArray.float64(0, 6)
    m = CArray.meld(a, a, axis: 1)
    m.add!(1)
    assert_equal [0, 12], m.shape
    assert_equal [], m.to_a
  end

  GMALLOC = "/usr/lib/libgmalloc.dylib"

  def test_writes_through_an_empty_meld_under_guard_malloc
    omit "Guard Malloc is macOS only" unless RUBY_PLATFORM =~ /darwin/ && File.exist?(GMALLOC)
    ext = File.expand_path("../../ext", __dir__)
    lib = File.expand_path("../../lib", __dir__)
    out, status = Open3.capture2e({ "DYLD_INSERT_LIBRARIES" => GMALLOC },
                                  RbConfig.ruby, "-I", ext, "-I", lib,
                                  "-rcarray", "-e", SCRIPT)
    assert status.success?, "child exited #{status.inspect}: #{out[-400..] || out}"
    assert_match(/ok/, out)
  end
end

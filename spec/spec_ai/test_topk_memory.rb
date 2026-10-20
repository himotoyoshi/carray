$LOAD_PATH.unshift File.expand_path('../../ext', __dir__)
$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)
require 'carray'
require 'test/unit'
require 'open3'

# nlargest / nsmallest keep a few times n cells per fiber, not a cell of
# work per cell of the array.  Measured in a child process as the growth
# of the malloc zone's high-water mark (malloc_statistics_t's
# max_size_in_use) over one call, on a 16 MB uint8 array: a work area
# proportional to the array would be hundreds of megabytes.  macOS only;
# glibc has no high-water mark to read.

class TestTopkMemory < Test::Unit::TestCase

  CHILD = <<~'RUBY'
    require "carray"
    require "fiddle"
    stats = Fiddle::Function.new(
      Fiddle::Handle::DEFAULT["malloc_zone_statistics"],
      [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID)
    peak = -> {
      buf = Fiddle::Pointer.malloc(32, Fiddle::RUBY_FREE)
      stats.call(nil, buf)
      buf[16, 8].unpack1("Q")      # malloc_statistics_t#max_size_in_use
    }
    a = CArray.uint8(1 << 24).seq!
    b = a.reshape(1 << 12, 1 << 12)
    GC.start
    before = peak.()
    eval(ARGV[0])
    puts peak.() - before
  RUBY

  def peak_growth (expr)
    inc = $LOAD_PATH.flat_map { |d| ["-I", d] }
    out, err, st = Open3.capture3(RbConfig.ruby, *inc, "-e", CHILD, expr)
    assert st.success?, err
    Integer(out)
  end

  def setup
    omit "the high-water mark is read from macOS's malloc zone" unless RUBY_PLATFORM =~ /darwin/
  end

  def test_the_meter_sees_an_allocation
    assert_operator peak_growth("CArray.uint8(1 << 24)"), :>=, 1 << 24
  end

  def test_work_area_does_not_grow_with_the_array
    [
      "a.nlargest_index(3, axis: 0)",
      "a.nsmallest_index(100, axis: 0)",
      "a.nlargest(10)",
      "b.nlargest_index(5, axis: 0)",
      "b.nsmallest(5, axis: 1)",
    ].each do |expr|
      assert_operator peak_growth(expr), :<, 1 << 20, expr
    end
  end

end

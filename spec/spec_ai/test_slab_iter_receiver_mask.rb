require "test/unit"
require "rbconfig"
require "open3"
require "carray"

# A block of each_slab / map_slab / reduce_slab that gives the receiver a
# mask in the middle of the walk.  What later slabs then show is not
# specified (it differs between the routes); the walk must not crash.

class TestSlabIterReceiverMask < Test::Unit::TestCase

  def run_child (body)
    inc = $LOAD_PATH.map { |d| ["-I", d] }.flatten
    src = "require 'carray'\n" + body + "\nputs :done\n"
    out, status = Open3.capture2e(RbConfig.ruby, *inc, "-e", src)
    [out, status]
  end

  CASES = {
    "each_slab one axis"   => "a = CArray.float64(4,5).seq!; a.each_slab(axis: 1) { |s| a[3,2] = UNDEF; s.to_a; s.mask }",
    "each_slab axis 0"     => "a = CArray.float64(4,5).seq!; a.each_slab(axis: 0) { |s| a[3,2] = UNDEF; s.to_a; s.mask }",
    "each_slab two axes"   => "b = CArray.float64(3,4,5).seq!; b.each_slab(axis: [1,2]) { |s| b[2,3,4] = UNDEF; s.count_masked }",
    "reduce_slab"          => "a = CArray.float64(4,5).seq!; a.reduce_slab(axis: 1) { |s| a[3,2] = UNDEF; s.sum }.to_a",
    "map_slab"             => "a = CArray.float64(4,5).seq!; a.map_slab(axis: 1) { |s| a[3,2] = UNDEF; s.mask; s * 1 }.to_a",
  }

  CASES.each do |name, body|
    define_method("test_#{name.tr(' ', '_')}_does_not_crash") do
      out, status = run_child(body)
      assert status.success?, "#{name}: child ended with #{status.inspect}\n#{out[0, 400]}"
      assert_match(/done/, out)
    end
  end

end

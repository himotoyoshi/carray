require "test/unit"
require "carray"
require "rbconfig"

# A CAObject hook (copy_addrs, copy_block, ...) receives the caller's buffer
# wrapped as a CArray.  The caller frees that buffer when the hook returns,
# but the wrap is a Ruby object and outlives the call: the collector scans
# the machine stack conservatively and still finds it there.  An object
# wrap is marked cell by cell, so it read a buffer that was gone.  The wrap
# is now taken back from the buffer when the hook returns.
#
# A view that owns its buffer and fills it through its transfers (CARemap,
# CAStack, CAMeld, and the descriptor views over a parent with no memory to
# lend) publishes the buffer only once it is filled: an object buffer
# published empty is marked cell by cell while the fill calls Ruby.

class TestCAObjectTransientWrap < Test::Unit::TestCase

  class Keeper < CAObject
    attr_reader :kept
    def initialize(back)
      @back = back
      super(back.data_type, back.shape)
    end
    private
    def fetch_addr(a) = @back[a]
    def store_addr(a, v) = (@back[a] = v)
    def copy_addrs(a, d)
      @kept = [a, d]
      d[] = @back[a]
    end
    def copy_block(s, c, t, d)
      @kept = [d]
      d[] = @back[*s.each_index.map { |k| [s[k], c[k], t[k]] }]
    end
  end

  def test_a_hook_cannot_keep_the_callers_buffer
    r = Keeper.new(CArray.object(3, 4) { |i, j| "s#{i}#{j}" })
    assert_equal(["s20", "s00"], r[CArray.int64(2) { [2, 0] }, 0].to_a.flatten)
    assert_equal(2, r.kept.size)
    assert_true(r.kept.none?(&:attached?))
    assert_equal([["s01", "s02"]], r[0..0, 1..2].to_a)
    assert_equal(1, r.kept.size)
    assert_true(r.kept.none?(&:attached?))
  end

  SCRIPT = <<~'RUBY'
    require "carray"
    class Cold < CAObject
      def initialize(back) = (@back = back; super(back.data_type, back.shape))
      private
      def fetch_addr(a) = @back[a]
      def store_addr(a, v) = (@back[a] = v)
      def copy_addrs(a, d) = (d[] = @back[a])
      def sync_addrs(a, d) = (@back[a] = d)
    end
    r = Cold.new(CArray.object(4, 6) { |i, j| "s#{i}#{j}" })
    sel = CArray.boolean(8, 6) { |i, j| (i + j).even? }
    views = [r.sort(axis: 1), CArray.stack([r, r]), CArray.meld([r, r])[sel]]
    GC.stress = true
    out = views.map { |v| v.to_a.flatten.size }
    GC.stress = false
    puts out.join(",")
  RUBY

  def test_object_views_over_a_cold_root_survive_collections
    out = IO.popen({ "MallocPreScribble" => "1" },
                   [RbConfig.ruby, *$LOAD_PATH.grep(/carray/).flat_map { |d| ["-I", d] },
                    "-e", SCRIPT], err: [:child, :out], &:read)
    assert_equal("24,48,24", out.strip.lines.last.to_s.strip, out[0, 400])
  end

end

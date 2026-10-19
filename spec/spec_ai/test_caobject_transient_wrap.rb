require "test/unit"
require "carray"
require_relative "../../utils/measure_leak"
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
    assert_true(r.kept.all? { |w| w.elements == 0 })
    assert_equal([["s01", "s02"]], r[0..0, 1..2].to_a)
    assert_equal(1, r.kept.size)
    assert_true(r.kept.all? { |w| w.elements == 0 })
  end

  # What a hook kept has no cells once the hook returns: reading it raises
  # or answers empty instead of reading the freed buffer.
  def test_a_kept_wrap_has_no_cells
    r = Keeper.new(CArray.float64(3, 4).seq!)
    r[CArray.int64(2) { [2, 0] }, 0].to_a
    r.kept.each do |w|
      assert_equal 0, w.elements
      assert_raise(IndexError) { w[0] }
      assert_equal [], w.to_a.flatten
      assert_equal 0.0, w.sum.to_f
    end
  end

  class DataKeeper < CAObject
    attr_reader :kept
    def initialize(back)
      @back = back
      super(back.data_type, back.shape)
    end
    private
    def fetch_addr(a) = @back[a]
    def copy_data(d) = (@kept = d; d[] = @back)
    def sync_data(d) = (@kept = d; @back[] = d)
  end

  def test_the_array_copy_data_was_given_has_no_cells_afterwards
    r = DataKeeper.new(CArray.float64(3, 4).seq!)
    assert_equal 66.0, r.sum
    assert_equal 0, r.kept.elements
    assert_raise(IndexError) { r.kept[0] }
    assert_equal 0.0, r.kept.sum.to_f
    assert_equal [], (r.kept + 1).to_a.flatten
    assert_equal 66.0, r.sum   # and the next call gets a wrap of its own
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

  # The data keeps its mask whatever the hook does with the wrap's: a mask
  # the hook kept has no cells once the object is gone, and is still a mask.
  class MaskKeeper < CAObject
    attr_reader :kept
    def initialize (back)
      @back = back
      super(back.data_type, back.shape)
      self.mask = 0
    end
    private
    def fetch_addr (a) = @back[a]
    def copy_data (d) = (d[] = @back; d[0] = UNDEF; @kept = d.mask)
    def create_mask; end
  end

  def test_a_mask_the_hook_kept_outlives_the_object
    r = MaskKeeper.new(CArray.float64(1000).seq!)
    assert_equal 1, r.copy.count_masked
    kept = r.kept
    r = nil
    GC.start
    filler = Array.new(50) { CArray.float64(1000).seq! }
    assert_equal CA_BOOLEAN, kept.data_type
    assert_equal 0, kept.elements
    filler.clear
  end

  # A copy_data that copies the object again: each call's mask is its own.
  def test_a_nested_copy_does_not_leak_the_inner_mask
    setup = <<~RUBY
      class Nest < CAObject
        def initialize (back) = (@back = back; super(back.data_type, back.shape))
        private
        def fetch_addr (a) = @back[a]
        def copy_data (d)
          d[] = @back
          if ! @in
            @in = true; copy; @in = false
          end
          d[0] = UNDEF if @in
        end
      end
    RUBY
    bytes = LeakMeter.bytes_per_call("Nest.new(CArray.float64(100_000).seq!).copy", setup: setup)
    omit "malloc zone statistics unavailable" if bytes.nil?
    assert_operator bytes, :<, 20_000, "the inner mask (100 KB) leaks per call"
  end

end

# A raise inside an attach window must not damage more than the array.
#
# Two kinds of state could outlive the window when Ruby raises inside it:
#
# - the lazy arena's depth.  The streaming reductions and the chunked
#   operator drivers enter the arena; a raise that skipped the exit left
#   one level behind, and after 32 of them every lazy expression in the
#   process failed, numeric ones included.
#
# - a cold parent's ptr.  The two-pass store of a gather view over a parent
#   with no memory of its own points parent->ptr at a scratch buffer for
#   the walk.  A PUT that raised with ptr still lent left the parent
#   pointing into a buffer that was already gone.
#
# Either takes the process down with it, so every case here runs in a child.
#
# Assertions that go through assert_broken pin behaviour that is still
# wrong, and name the correct outcome.  When a fix makes one fail, rewrite
# that test to assert the outcome it names rather than deleting it.

require "test/unit"
require "rbconfig"
require "carray"
require_relative "../../utils/measure_leak"

class TestAttachWindowRaiseProcess < Test::Unit::TestCase

  def assert_broken (actual, broken, fixed)
    assert_equal broken, actual,
                 "no longer broken -- rewrite this test to assert #{fixed}"
  end

  # Runs +script+ in a fresh process and returns [status, stdout].
  def run_child (script)
    inc = $LOAD_PATH.map { |d| ["-I", d] }.flatten
    out = IO.popen([RbConfig.ruby, *inc, "-e", "require 'carray'\n" + script],
                   err: File::NULL, &:read)
    [$?, out]
  end

  # --- the lazy arena --------------------------------------------------

  # How many arena levels one raising call leaves behind.
  def arena_levels_left (setup, expr)
    status, out = run_child(<<~RUBY)
      #{setup}
      d0 = CArray.__lazy_arena_depth__
      begin; #{expr}; rescue StandardError; end
      print CArray.__lazy_arena_depth__ - d0
    RUBY
    assert status.success?, "child failed: #{expr}"
    Integer(out)
  end

  OBJECT_WITH_A_STRING = <<~RUBY
    o = CArray.object(12) { |i| i }
    o[1] = "s"
  RUBY

  # Two operands that are not aliases take the chunked path.
  CHUNKED = <<~RUBY
    def sel (a) ; a[a.convert(CA_BOOLEAN) { true }] ; end
    o  = CArray.object(10) { |i| i }
    o[3] = "s"
    o2 = CArray.object(10) { |i| i }
    x  = CArray.int32(10).seq
    y  = CArray.int32(10)
  RUBY

  {
    "streaming_sum"          => [OBJECT_WITH_A_STRING, "o.lazy.sum"],
    "streaming_min"          => [OBJECT_WITH_A_STRING, "o.lazy.min"],
    "streaming_sum_of_a_sum" => [OBJECT_WITH_A_STRING, "(o.lazy + 1).sum"],
    "chunked_binop"          => [CHUNKED, "sel(o) + sel(o2)"],
    "chunked_integer_div"    => [CHUNKED, "sel(x) / sel(y)"],
    "chunked_triop"          => [CHUNKED, "sel(o).fma(sel(o2), sel(o2))"],
    "chunked_triop_bang"     => [CHUNKED, "sel(o).fma!(sel(o2), sel(o2))"],
    "chunked_bincmp"         => [CHUNKED, "sel(o) < sel(o2)"],
  }.each do |name, (setup, expr)|
    define_method("test_#{name}_restores_the_arena") do
      assert_equal 0, arena_levels_left(setup, expr)
    end
  end

  # The chunked run acquires an alias operand by attaching it; a raise in
  # the kernel must still detach it.
  def test_chunked_triop_detaches_an_alias_operand
    status, out = run_child(<<~RUBY)
      #{CHUNKED}
      av = CArray.object(10) { 1 }[0..9]
      d0 = CArray.__lazy_arena_depth__
      begin; sel(o).fma(sel(o2), av); rescue TypeError; end
      print av.attached?, " ", CArray.__lazy_arena_depth__ - d0
    RUBY
    assert status.success?
    assert_equal "false 0", out
  end

  def test_raising_lazy_sums_leave_later_lazy_expressions_working
    status, out = run_child(<<~RUBY)
      #{OBJECT_WITH_A_STRING}
      40.times { o.lazy.sum rescue nil }
      begin
        print (CArray.float64(100).seq.lazy * 2).sum
      rescue RuntimeError => e
        print e.message
      end
    RUBY
    assert status.success?
    assert_equal "9900.0", out
  end

  def test_lazy_materialise_restores_the_arena
    %w[(o.lazy+1).copy o.lazy.sqrt.copy (o.lazy<3).copy].each do |expr|
      assert_equal 0, arena_levels_left(OBJECT_WITH_A_STRING, expr), expr
    end
  end

  # --- a cold parent left pointing at a freed scratch buffer -----------

  FAILING_SYNC = <<~RUBY
    class FailingSync < CAObject
      attr_accessor :fail_sync
      def initialize (*dim)
        @src = CArray.int32(*dim).seq
        super(CA_INT32, dim)
      end
      def copy_data (d) ; d[] = @src ; end
      def sync_data (d)
        raise "sync failed" if @fail_sync
        @src[] = d
      end
      def fetch_addr (a) ; @src[a] ; end
      def store_addr (a, v)
        raise "store failed" if @fail_sync
        @src[a] = v
      end
    end
  RUBY

  # Stores through +view+ while the parent's sync fails, then reads the
  # parent.  Returns the child's status and what it printed.
  def store_then_read (dim, view)
    run_child(<<~RUBY)
      #{FAILING_SYNC}
      b = FailingSync.new(*#{dim})
      v = #{view}
      b.fail_sync = true
      begin
        v[] = CArray.int32(*v.shape).seq + 100
      rescue RuntimeError
      end
      b.fail_sync = false
      print b.attached?, " "
      $stdout.flush
      b.to_a
      print "survived"
    RUBY
  end

  {
    "select"      => [[6],    "b[CArray.boolean(6) { [1, 0, 1, 0, 1, 0] }]"],
    "grid"        => [[6],    "b[CArray.int64(3) { [0, 2, 4] }]"],
    "roll"        => [[6],    "b.roll(1)"],
    "tile"        => [[6],    "b.tile(2)"],
    "select_axis" => [[3, 4], "b[CArray.boolean(3) { [1, 0, 1] }, nil]"],
    "window"      => [[6],    "b.window(0..3)"],
  }.each do |name, (dim, view)|
    define_method("test_#{name}_store_leaves_the_parent_usable") do
      status, out = store_then_read(dim, view)
      assert status.success?, "the child died (signal #{status.termsig.inspect})"
      assert_equal "false survived", out
    end
  end

  def test_views_that_store_cell_by_cell_leave_the_parent_usable
    { [6] => "b[0..4]", [3, 4] => "b.T" }.each do |dim, view|
      status, out = store_then_read(dim, view)
      assert status.success?, view
      assert_equal "false survived", out, view
    end
  end

  # The same two-pass store with no CAObject: the PUT that raises is the
  # conversion of the caller's value.
  def test_object_fake_select_store_detaches_the_parent
    status, out = run_child(<<~RUBY)
      f = CArray.int32(6).seq.fake(CA_OBJECT)
      begin
        f[CArray.boolean(6) { [1, 0, 1, 0, 1, 0] }][] = CArray.object(3) { "zz" }
      rescue ArgumentError
      end
      print f.attached?
    RUBY
    assert status.success?
    assert_equal "false", out
  end

  # --- buffers that a raise must not strand -------------------------------

  # Bytes the malloc zone grows by per call of +expr+ after +setup+, or nil
  # where the measurement is not available.
  #
  # The buffers these cases strand are hundreds of kilobytes per call, while
  # the Ruby heap's own growth reads as up to a few tens of kilobytes per
  # call here, so the bound sits between the two.
  STRANDED_BUFFER_BOUND = 64 * 1024

  def malloc_growth_per_call (setup, expr)
    LeakMeter.bytes_per_call(expr, setup: setup)
  end

  # The object lane of the sort kernels orders pairs with <=>; a pair that
  # does not compare raises part way through, and the pair buffers go with
  # the unwind.
  def test_object_sort_frees_its_buffers_when_a_pair_does_not_compare
    omit "malloc zone statistics are macOS only" unless RUBY_PLATFORM =~ /darwin/
    setup = "o = CArray.object(20_000) { |i| i }; o[19_999] = Object.new"
    %w[o.sort_index o.rank_index o.partition_index(10_000)].each do |expr|
      growth = malloc_growth_per_call(setup, expr)
      omit "measurement unavailable" if growth.nil?
      assert_operator growth, :<, STRANDED_BUFFER_BOUND, expr
    end
  end

  # The value-hash discovery family keeps a hash table and its levels for
  # the length of the walk; an element whose #hash raises must not strand
  # them.
  def test_discovery_frees_its_tables_when_hash_raises
    omit "malloc zone statistics are macOS only" unless RUBY_PLATFORM =~ /darwin/
    setup = <<~SETUP
      class NoHash ; def hash ; raise "no hash" ; end ; end
      o = CArray.object(20_000) { |i| i }
      o[19_999] = NoHash.new
    SETUP
    %w[o.unique o.value_counts o.nunique o.categorize
       CA_OBJECT([1,2]).is_in(o)].each do |expr|
      growth = malloc_growth_per_call(setup, expr)
      omit "measurement unavailable" if growth.nil?
      assert_operator growth, :<, STRANDED_BUFFER_BOUND, expr
    end
  end

  # CArray.sort_addr orders its keys inside libc's sort; an object key that
  # does not compare must not unwind through it, stranding its buffers.
  def test_sort_addr_frees_its_buffers_when_keys_do_not_compare
    omit "malloc zone statistics are macOS only" unless RUBY_PLATFORM =~ /darwin/
    setup = "o = CArray.object(20_000) { |i| i }; o[19_999] = 's'"
    growth = malloc_growth_per_call(setup, "CArray.sort_addr(o)")
    omit "measurement unavailable" if growth.nil?
    assert_operator growth, :<, STRANDED_BUFFER_BOUND
  end

  # AddressBasis frees every region buffer when one region's write-back
  # raises.
  def test_address_basis_frees_its_regions_when_a_write_back_raises
    omit "malloc zone statistics are macOS only" unless RUBY_PLATFORM =~ /darwin/
    setup = <<~SETUP
      #{FAILING_SYNC}
      a = FailingSync.new(20_000)
      b = FailingSync.new(20_000)
      arrays = [b[1..-2], a[1..-2]]
    SETUP
    expr = "(CArray::AddressBasis.open(arrays, [true, true]) { a.fail_sync = true }) " \
           "rescue nil ; a.fail_sync = false"
    growth = malloc_growth_per_call(setup, expr)
    omit "measurement unavailable" if growth.nil?
    assert_operator growth, :<, STRANDED_BUFFER_BOUND
  end

  # --- a block of scratch allocated before the arguments are checked ---

  def test_address_basis_open_frees_its_block_when_an_argument_is_refused
    omit "malloc zone statistics are macOS only" unless RUBY_PLATFORM =~ /darwin/
    setup = <<~SETUP
      arrays = [CArray.int32(3).freeze] * 64
      flags  = [true] * 64               # writable, which a frozen array refuses
    SETUP
    growth = malloc_growth_per_call(setup, "CArray::AddressBasis.open(arrays, flags) {}")
    omit "measurement unavailable" if growth.nil?
    assert_operator growth, :<, 4096
  end

end

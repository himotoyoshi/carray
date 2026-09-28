# A raise inside an attach window that damages more than the array.
#
# Two kinds of state outlive the window when Ruby raises inside it:
#
# - the lazy arena's depth.  The streaming reductions and the chunked
#   operator drivers enter the arena without an ensure, so each raise
#   leaves one level behind; after 32 of them every lazy expression in the
#   process fails, numeric ones included.
#
# - a cold parent's ptr.  The two-pass store of a gather view over a parent
#   with no memory of its own points parent->ptr at a scratch buffer, calls
#   the parent's PUT, and restores ptr afterwards.  When the PUT raises the
#   restore is skipped, and the parent keeps a pointer into a buffer that
#   is already gone.
#
# Both take the process down with them, so every case here runs in a child.
#
# MOST OF THE ASSERTIONS BELOW PIN BEHAVIOUR THAT IS WRONG.  Each one goes
# through assert_broken, which names the correct outcome.  When a fix makes
# one fail, rewrite that test to assert the outcome it names rather than
# deleting it.  Tests whose name begins with `test_sound_` pin behaviour
# that is already right and must not change.

require "test/unit"
require "rbconfig"
require "carray"

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
    define_method("test_#{name}_leaves_an_arena_level") do
      assert_broken arena_levels_left(setup, expr), 1,
                    "that the arena is back at its depth"
    end
  end

  def test_leaked_levels_stop_every_lazy_expression
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
    assert_broken out.include?("all 32 slots in use"), true,
                  "that a numeric lazy sum still answers 9900.0"
  end

  def test_sound_lazy_materialise_restores_the_arena
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
    define_method("test_#{name}_store_leaves_the_parent_on_a_freed_buffer") do
      status, out = store_then_read(dim, view)
      assert_broken [out, status.termsig], ["true ", Signal.list["ABRT"]],
                    "that the parent reads back as 'false survived'"
    end
  end

  def test_sound_views_that_store_cell_by_cell_leave_the_parent_usable
    { [6] => "b[0..4]", [3, 4] => "b.T" }.each do |dim, view|
      status, out = store_then_read(dim, view)
      assert status.success?, view
      assert_equal "false survived", out, view
    end
  end

  # The same two-pass store with no CAObject: the PUT that raises is the
  # conversion of the caller's value.
  def test_object_fake_select_store_leaves_the_parent_attached
    status, out = run_child(<<~RUBY)
      f = CArray.int32(6).seq.fake(CA_OBJECT)
      begin
        f[CArray.boolean(6) { [1, 0, 1, 0, 1, 0] }][] = CArray.object(3) { "zz" }
      rescue ArgumentError
      end
      print f.attached?
    RUBY
    assert status.success?
    assert_broken out, "true", "that the fake view is detached"
  end

  # --- a block of scratch allocated before the arguments are checked ---

  def test_address_basis_open_frees_its_block_when_an_argument_is_refused
    omit "malloc zone statistics are macOS only" unless RUBY_PLATFORM =~ /darwin/
    status, out = run_child(<<~RUBY)
      begin
        require "fiddle"
        stats = Fiddle::Function.new(
          Fiddle::Handle::DEFAULT["malloc_zone_statistics"],
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID)
      rescue LoadError, Fiddle::DLError
        exit 2
      end
      in_use = -> {
        buf = Fiddle::Pointer.malloc(32, Fiddle::RUBY_FREE)
        stats.call(nil, buf)
        buf[8, 8].unpack1("Q")          # malloc_statistics_t#size_in_use
      }
      arrays = [CArray.int32(3).freeze] * 64
      flags  = [true] * 64               # writable, which a frozen array refuses
      call = -> { (CArray::AddressBasis.open(arrays, flags) {}) rescue nil }
      50.times { call.() }
      GC.start
      before = in_use.()
      200.times { call.() }
      GC.start
      print (in_use.() - before).fdiv(200)
    RUBY
    omit "measurement unavailable" if status.exitstatus == 2
    assert status.success?
    assert_broken Float(out) > 4096, true,
                  "that the malloc zone grows by less than 4096 bytes per call"
  end

end

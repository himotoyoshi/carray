# spec_ai/test_read_raise_cleanup.rb
#
# Methods that hold a work buffer while they read their source or run a
# block.  The read (a CAObject whose hook raises) or the block can raise,
# and the buffer must not be left behind:
#
#   sort_copy(kind: :stable)      the merge buffer
#   a | b, a & b (boolean, masked) the value / mask copies of both operands
#   CArray::AddressBasis.open     the region buffer
#   reduce_slab / map_slab        the output cell scratch (wide cells)
#   a reduction over CArray.stack the per-parent pointer table; the raise
#                                 the caller sees is the hook's own
#
# Each buffer is made large (128 KB to 2 MB), so a leak shows far above
# the 4 KB threshold of utils/measure_leak.rb (macOS only).

require "test/unit"
require "carray"
require_relative "../../utils/measure_leak"

class TestReadRaiseCleanup < Test::Unit::TestCase

  # A CAObject that reads from +src+ and raises from its +fail_at+-th read.
  FIXTURE = <<~RUBY
    class NthRead < CAObject
      attr_accessor :fail_at
      def initialize (src, fail_at)
        @src = src ; @fail_at = fail_at ; @calls = 0
        super(src.data_type, src.shape, bytes: src.bytes)
      end
      def reset ; @calls = 0 ; self ; end
      def tick ; @calls += 1 ; raise "read failed" if @calls >= @fail_at ; end
      def copy_data (data) ; tick ; data[] = @src ; end
      def fetch_addr (addr) ; tick ; @src[addr] ; end
      def fetch_index (idx) ; tick ; @src[*idx] ; end
    end
    class NthReadMasked < NthRead
      def initialize (src, fail_at) ; super ; self.mask = 0 ; end
      def create_mask ; end
      def mask_copy_data (data) ; data[] = @src.mask ; end
      def mask_fetch_addr (addr) ; @src.mask[addr] ; end
    end
  RUBY

  eval FIXTURE

  def assert_leaves_nothing (expr, setup, calls: 300)
    bytes = LeakMeter.bytes_per_call(expr, setup: FIXTURE + setup, calls: calls)
    omit "malloc zone statistics unavailable" if bytes.nil?
    assert_operator bytes, :<, 16384,
                    "#{expr}: the malloc zone grew #{bytes.round} bytes per call"
  end

  def test_sort_copy_stable
    assert_leaves_nothing "a.sort_copy(kind: :stable, axis: 0)",
      "a = NthRead.new(CArray.float64(1 << 18).seq, 1)", calls: 1000
  end

  KLEENE = <<~RUBY
    s = CArray.boolean(1 << 18) { |i| i % 2 == 1 } ; s[0] = UNDEF
    b = CArray.boolean(1 << 18) { true }
    a = NthReadMasked.new(s, 2)
  RUBY

  def test_kleene_or
    assert_leaves_nothing "a.reset; a | b", KLEENE, calls: 1000
  end

  def test_kleene_and
    assert_leaves_nothing "a.reset; a & b", KLEENE, calls: 1000
  end

  BASIS = <<~RUBY
    o = CArray.object(1 << 16) { 1.0 } ; o[5] = Object.new
    input = CArray.wrap_readonly(o, CA_FLOAT64)
  RUBY

  def test_address_basis_read
    assert_leaves_nothing "CArray::AddressBasis.open([input], [false]) { }", BASIS
  end

  def test_address_basis_read_for_writing
    assert_leaves_nothing "CArray::AddressBasis.open([input], [true]) { }", BASIS
  end

  SLAB = "a = CArray.fixlen(4, 2, bytes: 1 << 17)"

  def test_reduce_slab_value_of_wrong_type
    assert_leaves_nothing "a.reduce_slab(axis: 1) { |s| 3.5 }", SLAB
  end

  def test_reduce_slab_block_raises
    assert_leaves_nothing "a.reduce_slab(axis: 1) { |s| raise 'x' }", SLAB
  end

  def test_reduce_slab_with_init
    assert_leaves_nothing "a.reduce_slab(axis: 1, init: 0) { |acc, x| 3.5 }", SLAB
  end

  def test_map_slab_value_of_wrong_type
    assert_leaves_nothing "a.map_slab(axis: 1) { |s| 3.5 }", SLAB
  end

  # --- an input and an output walked together ----------------------------
  #
  # sort_copy(axis:) walks the source and the result fiber by fiber.  When
  # reading a source fiber raises, the result's walk is closed as well: it
  # held 8 bytes per outer axis (96 here) and its attach of the result.

  PAIRED = <<~RUBY
    o = CArray.object(*[2]*13) { 1.0 } ; o[*[0]*13] = Object.new
    v = CArray.wrap_readonly(o, CA_FLOAT64)
  RUBY

  def test_paired_walk_closes_both
    bytes = LeakMeter.bytes_per_call("v.sort_copy(axis: 12)", setup: PAIRED, calls: 20000)
    omit "malloc zone statistics unavailable" if bytes.nil?
    assert_operator bytes, :<, 50,
                    "sort_copy(axis:): the malloc zone grew #{bytes.round(1)} bytes per call"
  end

  def test_paired_walk_raises_the_read_failure
    o = CArray.object(2, 3) { 1.0 }
    o[0, 0] = Object.new
    v = CArray.wrap_readonly(o, CA_FLOAT64)
    assert_raise(TypeError) { v.sort_copy(axis: 1) }
    assert_raise(TypeError) { v.partition_copy(1, axis: 1) }
  end

  # --- CArray.stack: the hook's own exception reaches the caller ---------

  def stack_with_failing_parent (masked: false)
    src = CArray.float64(4, 5).seq
    src[0, 0] = UNDEF if masked
    klass = masked ? NthReadMasked : NthRead
    parents = Array.new(3) { klass.new(src, 10**9) }
    parents[1].fail_at = 1
    [CArray.stack(parents), parents]
  end

  def test_stack_reduction_reports_the_read_failure
    [false, true].each do |masked|
      st, parents = stack_with_failing_parent(masked: masked)
      [0, 1].each do |axis|
        e = assert_raise(RuntimeError) { st.sum(axis: axis) }
        assert_equal "read failed", e.message
      end
      parents[1].fail_at = 10**9
      parents.each(&:reset)
      assert_equal 3 * 19.0, st.sum(axis: 0)[3, 4]
    end
  end

  def test_stack_reduction_leaves_nothing
    setup = <<~RUBY
      src = CArray.float64(4).seq
      ps = Array.new(2000) { NthRead.new(src, 10**9) } ; ps[1].fail_at = 1
      st = CArray.stack(ps)
    RUBY
    bytes = LeakMeter.bytes_per_call("st.sum(axis: 0)", setup: FIXTURE + setup, calls: 300)
    omit "malloc zone statistics unavailable" if bytes.nil?
    assert_operator bytes, :<, 4096
  end

end

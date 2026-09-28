# Does a raise inside an attach window leave the window open?
#
# Between ca_attach (or ca_allocate) and ca_detach, a view holds an attach
# count and, for a view that is not an alias, a buffer of its own.  Ruby
# code runs inside many of these windows -- a map! block, a conversion of
# the caller's value, the object lane of a kernel -- and when it raises,
# the detach after it is skipped.  The view stays attached, its parent
# views with it, and a non-alias view keeps its buffer.
#
# MOST OF THE ASSERTIONS BELOW PIN BEHAVIOUR THAT IS WRONG.  Each one goes
# through assert_broken, which names the correct outcome.  When a fix makes
# one fail, rewrite that test to assert the outcome it names rather than
# deleting it.  Tests whose name begins with `test_sound_` pin behaviour
# that is already right and must not change.
#
# What is recorded for each case is the list of views the raise left
# attached, compared exactly, so a fix that releases one view of two shows
# up as well as one that releases both.

require "test/unit"
require "carray"

source_dir = File.expand_path("ext_source_smoke", __dir__)
$LOAD_PATH.unshift(source_dir)
begin
  require "source_smoke"
  SOURCE_SMOKE_BUILT = true
rescue LoadError
  SOURCE_SMOKE_BUILT = false
end

class TestAttachWindowRaiseLeaks < Test::Unit::TestCase

  # An object with no arithmetic, no comparison and no conversions.
  NOPE = Object.new

  # A CAObject whose sync can be made to fail, as a lazily backed array's
  # does when its I/O fails.
  class FailingSync < CAObject
    attr_accessor :fail_sync
    def initialize (*dim)
      @src = CArray.int32(*dim).seq
      super(CA_INT32, dim)
    end
    def copy_data (d)          ; d[] = @src ; end
    def sync_data (d)
      raise "sync failed" if @fail_sync
      @src[] = d
    end
    def fetch_addr (a)         ; @src[a] ; end
    def store_addr (a, v)
      raise "store failed" if @fail_sync
      @src[a] = v
    end
  end

  def setup
    @arena_depth = CArray.__lazy_arena_depth__
  end

  # None of these cases may move the lazy arena: a leaked arena level is
  # process-wide, and 32 of them stop every lazy expression in the rest of
  # the run.  Those cases live in test_attach_window_raise_process.rb, one
  # child process each.
  def teardown
    assert_equal @arena_depth, CArray.__lazy_arena_depth__,
                 "this case leaked a lazy arena level into the test process"
  end

  def assert_broken (actual, broken, fixed)
    assert_equal broken, actual,
                 "no longer broken -- rewrite this test to assert #{fixed}"
  end

  # Runs +action+, which raises +error+ (or returns, when +error+ is nil),
  # and returns which of +views+ are attached afterwards.
  def attached_after (views, error, &action)
    assert_equal views.map { false }, views.map(&:attached?),
                 "a view was attached before the call"
    if error
      assert_raise(error, &action)
    else
      action.call
    end
    views.map(&:attached?)
  end

  def self.pin_leak (name, error, broken, &build)
    define_method("test_#{name}") do
      views, action = instance_exec(&build)
      assert_broken attached_after(views, error, &action), broken,
                    "that no view is left attached"
    end
  end

  # --- victims ---------------------------------------------------------

  # A non-alias view (CASelect) over another view (CATranspose), so that
  # both a materialised buffer and a parent's count can be left behind.
  def int_select (type = CA_INT32)
    t = CArray.new(type, [4, 6]).seq!.T
    [t[t > 3], t]
  end

  # A block of a transposed object array with one cell that answers
  # nothing.  Operators leave the block attached; the transpose is not.
  def object_block
    o = CArray.object(4, 6) { 1 }
    o[1, 1] = NOPE
    t = o.T
    [t[1..4, nil], t]
  end

  # The same object array, selected rather than blocked.  The generated
  # reductions release the selection and leave its parent attached.
  def object_select
    o = CArray.object(4, 6) { 1 }
    o[1, 1] = NOPE
    t = o.T
    [t[t.convert(CA_BOOLEAN) { true }], t]
  end

  # --- the block or the caller's value raises inside the window --------

  %w[map! collect! map_with_index! map_index! map_with_addr! map_addr!].each do |m|
    pin_leak("#{m.delete('!')}_bang_block_raises", RuntimeError, [true, true]) do
      s, t = int_select
      [[s, t], -> { s.send(m) { raise "block" } }]
    end
  end

  pin_leak("map_bang_block_breaks", nil, [true, true]) do
    s, t = int_select
    [[s, t], -> { s.map! { break } }]
  end

  pin_leak("map_bang_block_returns_an_unstorable_value", ArgumentError, [true, true]) do
    s, t = int_select
    [[s, t], -> { s.map! { "x" } }]
  end

  pin_leak("convert_block_raises", RuntimeError, [true, true]) do
    s, t = int_select
    [[s, t], -> { s.convert { raise "block" } }]
  end

  pin_leak("store_all_from_an_unconvertible_array", ArgumentError, [true, true]) do
    s, t = int_select
    [[s, t], -> { s[] = ["x"] * s.elements }]
  end

  pin_leak("store_through_a_missing_method", NoMethodError, [true, true]) do
    s, t = int_select
    [[s, t], -> { s[:no_such_method] = 1 }]
  end

  pin_leak("seq_bang_with_an_unconvertible_start", TypeError, [true, true]) do
    s, t = int_select
    [[s, t], -> { s.seq!("x") }]
  end

  RAISING_RNG = Object.new
  def RAISING_RNG.rand (*) ; raise "rng" ; end

  pin_leak("random_bang_generator_raises", RuntimeError, [true, true]) do
    s, t = int_select(CA_FLOAT64)
    [[s, t], -> { s.random!(rng: RAISING_RNG) }]
  end

  pin_leak("randomn_bang_generator_raises", RuntimeError, [true, true]) do
    s, t = int_select(CA_FLOAT64)
    [[s, t], -> { s.randomn!(rng: RAISING_RNG) }]
  end

  pin_leak("shuffle_bang_with_an_unconvertible_axis", TypeError, [true, true]) do
    s, t = int_select
    [[s, t], -> { s.shuffle!(axis: "x") }]
  end

  pin_leak("scatter_add_bang_index_out_of_range", IndexError, [true, true]) do
    s, t = int_select
    [[s, t], -> { s.scatter_add!([100], 1) }]
  end

  pin_leak("count_of_a_view_with_an_unconvertible_keyword", TypeError, [true, true]) do
    s, t = int_select
    [[s, t], -> { CArray.int32(s.elements).count(s, min_count: "x") }]
  end

  pin_leak("index2addr_index_out_of_range", IndexError, [true]) do
    i  = CArray.int64(5).seq
    iv = i[i > 1]                                  # 2, 3, 4 against a length of 3
    [[iv], -> { CArray.int32(3, 4).index2addr(iv, CArray.int64(3).seq) }]
  end

  # The caller's own index array is what stays attached.
  pin_leak("grid_construction_index_out_of_range", IndexError, [true]) do
    i   = CArray.int64(4).seq
    idx = i[i < 2]
    a   = CArray.int32(4, 6).seq
    [[idx], -> { a[idx, CArray.int64(1) { [99] }] }]
  end

  RAISING_EQ = Object.new
  def RAISING_EQ.== (_) ; raise "eq" ; end

  pin_leak("equality_element_raises", RuntimeError, [true]) do
    o = CArray.object(4, 6).seq!
    o[1, 1] = RAISING_EQ
    v = o[nil, 0..4]
    [[v], -> { v == v.copy }]
  end

  pin_leak("sort_addr_elements_do_not_compare", TypeError, [true]) do
    o = CArray.object(4, 6).seq!
    o[1, 1] = "s"
    v = o[nil, 0..4]
    [[v], -> { v.sort_addr }]
  end

  def test_map_slab_block_result_does_not_convert
    a   = CArray.int32(4, 6).seq
    res = nil
    assert_raise(ArgumentError) do
      a.map_slab(axis: 1) { res = CArray.object(2, 6) { "x" }[1, nil] }
    end
    assert_broken res.attached?, true, "that the block's result is detached"
  end

  pin_leak("axis_group_scan_element_does_not_add", TypeError, [true, false]) do
    o = CArray.object(3, 4) { 1 }
    o[1, 2] = NOPE
    t = o.T
    v = t[0..3, nil]
    cat = CArray.object(4) { |i| %w[a b a b][i] }.categorize
    [[v, t], -> { v[cat, nil].cumsum(axis: :group) }]
  end

  # --- the object lane of an operator or a generated kernel raises -----

  {
    "negate"          => [NoMethodError, ->(v) { -v }],
    "floor"           => [NoMethodError, ->(v) { v.floor }],
    "sqrt_bang"       => [NoMethodError, ->(v) { v.sqrt! }],
    "less_than"       => [NoMethodError, ->(v) { v < 1 }],
    "fma"             => [NoMethodError, ->(v) { v.fma(1, 1) }],
    "fma_bang"        => [NoMethodError, ->(v) { v.fma!(1, 1) }],
    "clip"            => [NoMethodError, ->(v) { v.clip(0, 3) }],
    "cumsum"          => [TypeError,     ->(v) { v.cumsum }],
    "sum"             => [TypeError,     ->(v) { v.sum }],
    "sum_axis"        => [TypeError,     ->(v) { v.sum(axis: 0) }],
    "search_nearest"  => [TypeError,     ->(v) { v.search_nearest(1) }],
  }.each do |name, (error, op)|
    pin_leak("object_block_#{name}", error, [true, false]) do
      v, t = object_block
      [[v, t], -> { op.(v) }]
    end
  end

  {
    "sum"             => [TypeError,     ->(v) { v.sum }],
    "min"             => [NoMethodError, ->(v) { v.min }],
    "mean"            => [TypeError,     ->(v) { v.mean }],
    "variance"        => [TypeError,     ->(v) { v.variance }],
    "sort_index"      => [ArgumentError, ->(v) { v.sort_index }],
    "rank_index"      => [ArgumentError, ->(v) { v.rank_index }],
    "partition_index" => [ArgumentError, ->(v) { v.partition_index(1) }],
  }.each do |name, (error, op)|
    pin_leak("object_select_#{name}", error, [false, true]) do
      v, t = object_select
      [[v, t], -> { op.(v) }]
    end
  end

  pin_leak("object_reshape_tiled_sum_along_axis_0", TypeError, [true]) do
    o = CArray.object(32 * 64).seq!
    o[5] = NOPE
    r = o.reshape(32, 64)                   # large enough to take the tiled path
    [[r], -> { r.sum(axis: 0) }]
  end

  pin_leak("object_stack_sum_along_axis_1", TypeError, [true, true]) do
    o = CArray.object(4, 6).seq!
    o[1, 1] = NOPE
    v1 = o[nil, 0..4]
    v2 = o[nil, 1..5]
    [[v1, v2], -> { CArray.stack([v1, v2]).sum(axis: 1) }]
  end

  pin_leak("integer_division_by_zero", ZeroDivisionError, [true]) do
    v = CArray.int32(4, 6).seq[1..2, nil]
    [[v], -> { v / 0 }]
  end

  pin_leak("integer_div_bang_by_zero", ZeroDivisionError, [true, true]) do
    s, t = int_select
    [[s, t], -> { s.div!(0) }]
  end

  # --- the core's own entry points -------------------------------------

  # ca_sync raises (the parent is read-only) and the detach after it is
  # skipped.
  pin_leak("pow_bang_on_a_view_of_a_frozen_array", RuntimeError, [true, true]) do
    s, t = int_select(CA_FLOAT64)
    t.parent.freeze
    [[s, t], -> { s.pow!(2) }]
  end

  # The parent's sync raises inside fill_data.
  {
    "bits"     => ->(b) { b.bits },
    "bitfield" => ->(b) { b.bitfield(0..1, CA_INT8) },
  }.each do |name, mk|
    pin_leak("#{name}_fill_parent_sync_raises", RuntimeError, [true]) do
      b = FailingSync.new(8)
      v = mk.(b)
      b.fail_sync = true
      [[b], -> { v.fill(1) }]
    end
  end

  # ca_allocate raises the view's count before calling the slot, and does
  # not lower it again when the slot raises.  The count is invisible while
  # ptr is NULL; the next attach and detach pair then leave the view
  # attached, holding the source's pointer published.
  def test_allocate_slot_raises
    omit "source_smoke not built" unless SOURCE_SMOKE_BUILT
    str = ("\0" * 12).dup
    src = CASmokeSource.new(str, [3, 4])
    src.seq!(1)
    v = src[nil, 0..2]
    src.revoke!
    assert_raise(RuntimeError) { v[] = [7] * 9 }
    str << "\0"                               # the owner is valid again
    assert_equal [[1, 2, 3], [5, 6, 7], [9, 10, 11]], v.to_a
    assert_broken [v.attached?, src.hold_count], [true, 1],
                  "that the view is detached and the source holds nothing"
  end

  # --- already right ----------------------------------------------------

  def test_sound_methods_that_release_the_view
    {
      "sort"   => ->(s) { s.sort },
      "each"   => ->(s) { s.each { raise "block" } },
      "map"    => ->(s) { s.map { raise "block" } },
      "inject" => ->(s) { s.inject { raise "block" } },
    }.each do |name, op|
      s, t = int_select
      (op.(s) rescue nil)
      assert_equal [false, false], [s.attached?, t.attached?], name
    end
  end

end

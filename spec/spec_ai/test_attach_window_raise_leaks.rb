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

  # The fixed form of pin_leak: the raise leaves no view attached.
  def self.releases (name, error, &build)
    define_method("test_#{name}") do
      views, action = instance_exec(&build)
      assert_equal views.map { false }, attached_after(views, error, &action)
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
  # nothing.
  def object_block
    o = CArray.object(4, 6) { 1 }
    o[1, 1] = NOPE
    t = o.T
    [t[1..4, nil], t]
  end

  # The same object array, selected rather than blocked, so that a walk
  # over it materialises a buffer of its own.
  def object_select
    o = CArray.object(4, 6) { 1 }
    o[1, 1] = NOPE
    t = o.T
    [t[t.convert(CA_BOOLEAN) { true }], t]
  end

  # --- the block or the caller's value raises inside the window --------

  %w[map! collect! map_with_index! map_index! map_with_addr! map_addr!].each do |m|
    releases("#{m.delete('!')}_bang_block_raises", RuntimeError) do
      s, t = int_select
      [[s, t], -> { s.send(m) { raise "block" } }]
    end
  end

  releases("map_bang_block_breaks", nil) do
    s, t = int_select
    [[s, t], -> { s.map! { break } }]
  end

  releases("map_bang_block_returns_an_unstorable_value", ArgumentError) do
    s, t = int_select
    [[s, t], -> { s.map! { "x" } }]
  end

  releases("convert_block_raises", RuntimeError) do
    s, t = int_select
    [[s, t], -> { s.convert { raise "block" } }]
  end

  releases("store_all_from_an_unconvertible_array", ArgumentError) do
    s, t = int_select
    [[s, t], -> { s[] = ["x"] * s.elements }]
  end

  releases("store_through_a_missing_method", NoMethodError) do
    s, t = int_select
    [[s, t], -> { s[:no_such_method] = 1 }]
  end

  releases("seq_bang_with_an_unconvertible_start", TypeError) do
    s, t = int_select
    [[s, t], -> { s.seq!("x") }]
  end

  RAISING_RNG = Object.new
  def RAISING_RNG.rand (*) ; raise "rng" ; end

  releases("random_bang_generator_raises", RuntimeError) do
    s, t = int_select(CA_FLOAT64)
    [[s, t], -> { s.random!(rng: RAISING_RNG) }]
  end

  releases("randomn_bang_generator_raises", RuntimeError) do
    s, t = int_select(CA_FLOAT64)
    [[s, t], -> { s.randomn!(rng: RAISING_RNG) }]
  end

  releases("shuffle_bang_with_an_unconvertible_axis", TypeError) do
    s, t = int_select
    [[s, t], -> { s.shuffle!(axis: "x") }]
  end

  releases("scatter_add_bang_index_out_of_range", IndexError) do
    s, t = int_select
    [[s, t], -> { s.scatter_add!([100], 1) }]
  end

  releases("count_of_a_view_with_an_unconvertible_keyword", TypeError) do
    s, t = int_select
    [[s, t], -> { CArray.int32(s.elements).count(s, min_count: "x") }]
  end

  releases("index2addr_index_out_of_range", IndexError) do
    i  = CArray.int64(5).seq
    iv = i[i > 1]                                  # 2, 3, 4 against a length of 3
    [[iv], -> { CArray.int32(3, 4).index2addr(iv, CArray.int64(3).seq) }]
  end

  # The caller's own index array is what stays attached.
  releases("grid_construction_index_out_of_range", IndexError) do
    i   = CArray.int64(4).seq
    idx = i[i < 2]
    a   = CArray.int32(4, 6).seq
    [[idx], -> { a[idx, CArray.int64(1) { [99] }] }]
  end

  RAISING_EQ = Object.new
  def RAISING_EQ.== (_) ; raise "eq" ; end

  releases("equality_element_raises", RuntimeError) do
    o = CArray.object(4, 6).seq!
    o[1, 1] = RAISING_EQ
    v = o[nil, 0..4]
    [[v], -> { v == v.copy }]
  end

  releases("sort_addr_elements_do_not_compare", TypeError) do
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
    assert_equal false, res.attached?
  end

  releases("axis_group_scan_element_does_not_add", TypeError) do
    o = CArray.object(3, 4) { 1 }
    o[1, 2] = NOPE
    t = o.T
    v = t[0..3, nil]
    cat = CArray.object(4) { |i| %w[a b a b][i] }.categorize
    [[v, t], -> { v[cat, nil].cumsum(axis: :group) }]
  end

  # --- the object lane of an operator or a generated kernel raises -----

  # The operator drivers call the object lane with the block attached; a
  # raise there releases it.
  {
    "negate"          => [NoMethodError, ->(v) { -v }],
    "floor"           => [NoMethodError, ->(v) { v.floor }],
    "sqrt_bang"       => [NoMethodError, ->(v) { v.sqrt! }],
    "less_than"       => [NoMethodError, ->(v) { v < 1 }],
    "fma"             => [NoMethodError, ->(v) { v.fma(1, 1) }],
    "fma_bang"        => [NoMethodError, ->(v) { v.fma!(1, 1) }],
    "clip"            => [NoMethodError, ->(v) { v.clip(0, 3) }],
  }.each do |name, (error, op)|
    releases("object_block_#{name}", error) do
      v, t = object_block
      [[v, t], -> { op.(v) }]
    end
  end

  # The other operator paths: the bang forms, one operand gathered and the
  # other attached, the chunked run of a bang triop, the comparisons, and
  # an integer division by zero.
  def self.select_all (a) ; a[a.convert(CA_BOOLEAN) { true }] ; end

  {
    "object_add_bang"            => [NoMethodError, ->(v) { v.add!(1) }],
    "object_plus_a_gathered_operand" => [NoMethodError, ->(v) {
      w = select_all(CArray.object(4, 6) { 1 })
      v + w.reshape(6, 4)[1..4, nil]
    }],
    "object_fma_bang_chunked"    => [NoMethodError, ->(v) {
      o = CArray.object(4, 6) { 1 }
      a = select_all(o.T[1..4, nil].copy).reshape(4, 4)
      b = select_all(o.T[1..4, nil].copy).reshape(4, 4)
      v.fma!(a, b)
    }],
    "object_is_nan"              => [NoMethodError, ->(v) { v.is_nan }],
    "object_le_an_attached_operand" => [NoMethodError, ->(v) { v.le(v.copy) }],
  }.each do |name, (error, op)|
    releases(name, error) do
      v, t = object_block
      [[v], -> { op.(v) }]
    end
  end

  {
    "integer_mod_zero"      => ->(v) { v % 0 },
    "integer_mod_bang_zero" => ->(v) { v.mod!(0) },
  }.each do |name, op|
    releases(name, ZeroDivisionError) do
      t = CArray.int32(4, 6).seq.T
      v = t[1..4, nil]
      [[v], -> { op.(v) }]
    end
  end

  # The object lane of a generated kernel calls Ruby for every cell; a raise
  # there releases what the walk holds.
  {
    "cumsum"          => [TypeError,     ->(v) { v.cumsum }],
    "sum"             => [TypeError,     ->(v) { v.sum }],
    "sum_axis"        => [TypeError,     ->(v) { v.sum(axis: 0) }],
    "search_nearest"  => [TypeError,     ->(v) { v.search_nearest(1) }],
    "search_nearest_array" => [TypeError, ->(v) { v.search_nearest(CA_OBJECT([1, 2])) }],
  }.each do |name, (error, op)|
    releases("object_block_#{name}", error) do
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
    releases("object_select_#{name}", error) do
      v, t = object_select
      [[v, t], -> { op.(v) }]
    end
  end

  # Large enough that a numeric array takes the tiled reduction; the object
  # lane walks the view instead.
  releases("object_reshape_sum_along_axis_0", TypeError) do
    o = CArray.object(32 * 64).seq!
    o[5] = NOPE
    r = o.reshape(32, 64)
    [[r], -> { r.sum(axis: 0) }]
  end

  releases("object_stack_sum_along_axis_1", TypeError) do
    o = CArray.object(4, 6).seq!
    o[1, 1] = NOPE
    v1 = o[nil, 0..4]
    v2 = o[nil, 1..5]
    [[v1, v2], -> { CArray.stack([v1, v2]).sum(axis: 1) }]
  end

  # A search with an array query attaches the source and the query together;
  # a query that does not convert to the source's type raises in the second.
  releases("search_query_does_not_convert", ArgumentError) do
    t = CArray.int32(4, 6).seq.T
    v = t[1..4, nil]
    [[v, t], -> { v.search(CA_OBJECT([1, "x"])) }]
  end

  releases("integer_division_by_zero", ZeroDivisionError) do
    v = CArray.int32(4, 6).seq[1..2, nil]
    [[v], -> { v / 0 }]
  end

  releases("integer_div_bang_by_zero", ZeroDivisionError) do
    s, t = int_select
    [[s, t], -> { s.div!(0) }]
  end

  # The value-hash discovery family keys an object cell on #hash and
  # re-checks it with #eql?, both calls into Ruby inside the walk.
  class NoHash
    def hash ; raise "no hash" ; end
  end

  def self.discovery_victim
    o = CArray.object(4, 6) { 1 }
    o[1, 1] = NoHash.new
    t = o.T
    [t[1..4, nil], t]
  end

  {
    "unique"          => ->(v) { v.unique },
    "value_counts"    => ->(v) { v.value_counts },
    "nunique"         => ->(v) { v.nunique },
    "nunique_axis"    => ->(v) { v.nunique(axis: 1) },
    "mask_duplicates" => ->(v) { v.mask_duplicates },
    "is_mode"         => ->(v) { v.is_mode },
    "mode"            => ->(v) { v.mode },
    "is_in"           => ->(v) { v.is_in([1, 2]) },
    "is_in_as_values" => ->(v) { CA_OBJECT([1, 2]).is_in(v) },
    "intersection"    => ->(v) { v.intersection(CA_OBJECT([1, 2])) },
    "difference"      => ->(v) { v.difference(CA_OBJECT([1, 2])) },
    "union"           => ->(v) { v.union(CA_OBJECT([1, 2])) },
    "locate_addr"     => ->(v) { v.locate_addr(CA_OBJECT([1, 2])) },
    "locate_addr_as_reference" => ->(v) { CA_OBJECT([1, 2]).locate_addr(v) },
    "categorize"      => ->(v) { v.categorize },
  }.each do |name, op|
    releases("discovery_#{name}_hash_raises", RuntimeError) do
      v, t = self.class.discovery_victim
      [[v, t], -> { op.(v) }]
    end
  end

  # --- the core's own entry points -------------------------------------

  # ca_sync raises (the parent is read-only); the window is closed anyway.
  releases("pow_bang_on_a_view_of_a_frozen_array", RuntimeError) do
    s, t = int_select(CA_FLOAT64)
    t.parent.freeze
    [[s, t], -> { s.pow!(2) }]
  end

  # The parent's sync raises inside fill_data.
  {
    "bits"     => ->(b) { b.bits },
    "bitfield" => ->(b) { b.bitfield(0..1, CA_INT8) },
  }.each do |name, mk|
    releases("#{name}_fill_parent_sync_raises", RuntimeError) do
      b = FailingSync.new(8)
      v = mk.(b)
      b.fail_sync = true
      [[b], -> { v.fill(1) }]
    end
  end

  # ca_allocate takes the view's attach level before calling the slot, and
  # must give it back when the slot raises.  A level left behind would be
  # invisible while ptr is NULL; the next attach and detach pair would then
  # leave the view attached, holding the source's pointer published.
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
    assert_equal [false, 0], [v.attached?, src.hold_count]
  end

  # ca_attach_n takes all of its arrays or none: the values fail to
  # convert after the array and the addresses were attached.
  releases("scatter_add_bang_values_do_not_convert", ArgumentError) do
    s, t = int_select
    [[s, t], -> { s.scatter_add!([0, 1, 2], CArray.object(3) { "x" }) }]
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

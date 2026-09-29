# What an array answers after a raise inside an attach window.
#
# A window that raises part way still pushes back the cells already
# written: an entity has no separate buffer, so those cells are simply
# there, and a view of it answers the same.
#
# Assertions that go through assert_broken pin behaviour that is still
# wrong, and name the correct outcome.  When a fix makes one fail, rewrite
# that test to assert the outcome it names rather than deleting it.

require "test/unit"
require "carray"

class TestAttachWindowRaiseValues < Test::Unit::TestCase

  def assert_broken (actual, broken, fixed)
    assert_equal broken, actual,
                 "no longer broken -- rewrite this test to assert #{fixed}"
  end

  # map! raises part way through a selection.  The selection lets go of
  # the buffer it materialised, so every read afterwards goes to the parent.
  def test_selection_reads_the_parent_after_map_bang_raises
    b = CArray.int32(3, 4).seq
    v = b[b > 3]
    assert_raise(RuntimeError) { v.map! { |x| x == 10 ? raise("block") : x * 100 } }
    b[1, 0] = -7
    assert_equal(-7, v[0])
    assert_equal [[-7, 500, 600], 1093.0], [v.to_a[0, 3], v[0..2].sum]
  end

  # The same raising operation on an entity and on a view of an identical
  # entity leaves the same cells written.
  {
    "map_bang"     => [RuntimeError,  ->(x) { x.map! { |e| e == 5 ? raise("block") : e * 10 } }],
    "store_array"  => [ArgumentError, ->(x) { x[] = [10, 11, 12, "z", 14, 15, 16, 17] }],
    "scatter_add"  => [IndexError,    ->(x) { x.scatter_add!([0, 1, 99], 5) }],
    "map_with_addr" => [RuntimeError, ->(x) { x.map_with_addr! { |e, i| i == 3 ? raise("block") : -e } }],
  }.each do |name, (error, op)|
    define_method("test_#{name}_writes_the_same_cells_through_a_view") do
      entity = CArray.int32(8).seq
      assert_raise(error) { op.(entity) }
      parent = CArray.int32(8).seq
      view   = parent[parent >= 0]
      assert_raise(error) { op.(view) }
      assert_not_equal CArray.int32(8).seq.to_a, entity.to_a, "nothing was written"
      assert_equal entity.to_a, parent.to_a
    end
  end

  def test_object_seq_bang_writes_the_same_cells_through_a_view
    entity = CArray.object(4) { 0 }
    assert_raise(TypeError) { entity.seq!(1, "x") }
    parent = CArray.object(4) { 0 }
    view   = parent[parent.convert(CA_BOOLEAN) { true }]
    assert_raise(TypeError) { view.seq!(1, "x") }
    assert_equal [1, 0, 0, 0], entity.to_a
    assert_equal entity.to_a, parent.to_a
  end

  # A store that fails converting the value clears the cycle check it set,
  # so later accesses are not reported as cyclic references.
  def test_failed_object_store_clears_the_cycle_check
    f = CArray.int32(3).fake(CA_OBJECT)
    assert_raise(ArgumentError) { f[0] = "zz" }
    assert_equal 0, f[1]
    f[2] = 9
    assert_equal [0, 0, 9], f.parent.to_a
  end

  # --- a mask built from operands whose masks cannot be read ------------

  # A CAObject whose mask reads fail until told otherwise.
  class FlakyMask < CAObject
    attr_accessor :fail_mask
    def initialize (bits)
      @src  = CArray.int32(bits.size).seq
      @bits = CA_BOOLEAN(bits)
      super(CA_INT32, [bits.size])
      self.mask = 0
    end
    def create_mask ; end
    def copy_data (d)  ; d[] = @src ; end
    def fetch_addr (a) ; @src[a] ; end
    def mask_copy_data (d)
      raise "mask copy failed" if @fail_mask
      d[] = @bits
    end
  end

  # A lazy node builds its mask from its operands' masks when first asked.
  # When reading one of those raises, no mask is kept: the next request
  # builds it again, rather than finding a half-made one.
  {
    "binop"  => [->(x, y) { x.lazy + y.lazy },              [true, false, true, true]],
    "bincmp" => [->(x, y) { x.lazy < y.lazy },              [true, false, true, true]],
    "triop"  => [->(x, y) { x.lazy.fma(y.lazy, x.lazy) },   [true, false, true, true]],
    "moncmp" => [->(x, y) { x.lazy.is_nan },                [true, false, false, true]],
  }.each do |name, (build, mask)|
    define_method("test_#{name}_mask_is_built_again_after_a_failed_read") do
      x = FlakyMask.new([1, 0, 0, 1])
      y = FlakyMask.new([0, 0, 1, 0])
      node = build.(x, y)
      x.fail_mask = true
      assert_raise_message("mask copy failed") { node.mask }
      x.fail_mask = false
      assert_equal mask, node.mask.to_a
    end
  end

  # --- regions written back one by one --------------------------------

  # A CAObject whose write-back can be made to fail, as a lazily backed
  # array's does when its I/O fails.
  class FailingSync < CAObject
    attr_accessor :fail_sync
    attr_reader :src
    def initialize (*dim)
      @src = CArray.int32(*dim).seq
      super(CA_INT32, dim)
    end
    def copy_data (d)     ; d[] = @src ; end
    def sync_data (d)
      raise "sync failed" if @fail_sync
      @src[] = d
    end
    def fetch_addr (a)    ; @src[a] ; end
    def store_addr (a, v)
      raise "store failed" if @fail_sync
      @src[a] = v
    end
  end

  # AddressBasis writes each region back when the block ends; a region
  # whose write-back raises keeps no other region from being written, and
  # an exception the block raised is the one that propagates.
  def test_address_basis_writes_back_every_region_when_one_refuses
    a = FailingSync.new(6)
    b = FailingSync.new(6)
    written = []
    b.define_singleton_method(:sync_data) { |d| written << d.to_a ; super(d) }
    b.define_singleton_method(:store_addr) { |i, v| written << [i, v] ; super(i, v) }
    arrays = [b[1..3], a[1..3]]              # closed last to first: a first
    assert_raise_message("store failed") do
      CArray::AddressBasis.open(arrays, [true, true]) { a.fail_sync = true }
    end
    a.fail_sync = false
    assert_not_empty written
    assert_raise_message("block") do
      CArray::AddressBasis.open(arrays, [true, true]) { a.fail_sync = true ; raise "block" }
    end
    a.fail_sync = false
  end

end

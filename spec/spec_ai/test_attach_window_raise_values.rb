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

  # A store that fails converting the value leaves the cycle check on, and
  # every later access reports a cyclic reference.
  def test_failed_object_store_leaves_the_cycle_check_on
    f = CArray.int32(3).fake(CA_OBJECT)
    assert_raise(ArgumentError) { f[0] = "zz" }
    e = (f[1] rescue $!)
    assert_broken e.is_a?(RuntimeError) && e.message.include?("cyclic reference"),
                  true, "that f[1] answers 1"
  end

end

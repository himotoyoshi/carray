# A view that works in a buffer of its own attaches its parent and
# allocates the buffer.  When the allocation fails, the slot has raised
# before publishing ca->ptr, so ca_attach has no detach slot to call: the
# parent's attach must not be left behind.  A parent left attached keeps the
# buffer it materialised, reads that copy instead of its root, and takes
# writes into it that never reach the root.
#
# The view is made larger than the address space (tile / grid / window), so
# that allocating it fails on any machine: macOS grants several terabytes
# without touching them, and a view of that size would then really be filled.
# map! goes through the attach slot, seq! through the allocate slot.

require "test/unit"
require "carray"

class TestViewAttachAllocRaise < Test::Unit::TestCase

  N = 1 << 22
  G = 1 << 23

  VIEWS = {
    "tile"   => ->(p) { p.tile(N, N) },
    "grid"   => ->(p) { i = CArray.int64(G).seq! % 3; p[i, i] },
    "window" => ->(p) { p.window(0...(N * N), 0...3) },
  }

  OPS = {
    "map!" => ->(v) { v.map! { |x| x } },
    "seq!" => ->(v) { v.seq! },
  }

  VIEWS.each do |vname, make|
    OPS.each do |oname, op|
      define_method("test_#{vname}_#{oname.delete('!')}_releases_parent") do
        root   = CArray.float64(4, 6).seq!
        parent = root[0..2, (0..5).step(2)]     # materialises when attached
        view   = make.(parent)
        assert_raise(NoMemoryError) { op.(view) }
        assert_false parent.attached?, "#{vname}.#{oname}: parent left attached"
        root[0, 0] = 1000.0
        assert_equal 1000.0, parent[0, 0], "#{vname}.#{oname}: parent reads a stale copy"
        parent[1, 1] = -5.0
        assert_equal(-5.0, root[1, 2], "#{vname}.#{oname}: write through parent lost")
      end
    end
  end
end

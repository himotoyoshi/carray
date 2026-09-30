# spec_ai/test_sort_copy_flatten_gc.rb
#
# `sort_copy` without `axis:` sorts a flattened view of the receiver.  That
# view is a temporary of the method, and reading a CAObject runs Ruby code,
# so a GC can start while the view is being read.  The view has to stay
# alive until the sort is done.  GC.stress makes the collection happen at
# every allocation.

require "test/unit"
require "carray"

class TestSortCopyFlattenGC < Test::Unit::TestCase

  class Reader < CAObject
    def initialize (src)
      @src = src
      super(src.data_type, src.shape, bytes: src.bytes)
    end
    def copy_data (data)
      data[] = @src
    end
    def fetch_addr (addr)
      @src[addr]
    end
  end

  def sort_under_stress (a, **kw)
    GC.stress = true
    a.sort_copy(**kw)
  ensure
    GC.stress = false
  end

  def test_quick
    src = CArray.float64(4, 50).random
    assert_equal src.flatten.sort_copy, sort_under_stress(Reader.new(src))
  end

  def test_stable
    src = CArray.int32(4, 50).random(100)
    assert_equal src.flatten.sort_copy(kind: :stable),
                 sort_under_stress(Reader.new(src), kind: :stable)
  end

end

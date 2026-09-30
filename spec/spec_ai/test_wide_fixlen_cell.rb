# spec_ai/test_wide_fixlen_cell.rb
#
# Kernels that hold one fixlen cell of scratch (the query of a search, the
# value counted, the pivot of a partition) take it from the heap: a cell
# can be megabytes wide, and on the stack an 8 MB cell overflowed it
# (SystemStackError).

require "test/unit"
require "carray"

class TestWideFixlenCell < Test::Unit::TestCase

  def wide (bytes)
    z = CArray.fixlen(4, bytes: bytes)
    %w[a b c d].each_with_index { |s, i| z[i] = s }
    z
  end

  [1 << 10, 1 << 23, 1 << 25].each do |bytes|
    define_method("test_cell_of_#{bytes}_bytes") do
      z = wide(bytes)
      assert_equal 2, z.bsearch("c")
      assert_equal 2, z.search("c")
      assert_equal 1, z.count("b")
      assert_equal 4, z.partition_copy(1).elements
      assert_equal z[1], z.partition_copy(1)[1]
    end
  end

end

# Regression test for ca_slab double-detach BUG on masked CAStride/CABlock src.
#
# Before the fix, ca_slab_build_slab_view set the slab_view's data-side attach
# counter to 1 (forcing user-side ca_attach into the increment-only path) but
# left the auto-created mask's counter at 0.  A user `slab.to_a` (ca_attach
# + ca_detach pair) then stayed net-zero on data (1->2->1) but over-detached
# on mask (0->1->0 invokes ca_stride_func_detach, NULLing the borrowed T1
# mask ptr and unilaterally detaching the root mask).  Combined with a
# per-cell block (= GC pressure), the 2nd consecutive map_slab call crashed
# in ca_iter_state_finish with "[BUG] tried to detach a detached array".

require 'test/unit'
require 'carray'

class TestMapSlabDoubleDetach < Test::Unit::TestCase

  def test_repeated_map_slab_with_to_a_and_per_cell_block_on_masked_view
    a = CArray.float64(10) { |i| i.to_f }
    a[CA_SIZE([1, 4, 7])] = UNDEF

    # 2 iters: 1st leaves state in a bad form; 2nd triggers the BUG.
    # The combo (to_a + per-cell init form) is required to reproduce.
    2.times do
      a.flatten.map_slab(axis: 0, data_type: :boolean) do |s|
        _ = s.to_a
        CArray.boolean(s.elements) { |i| 0 }
      end
    end
  end

  def test_repeated_map_slab_on_masked_block_view
    a = CArray.float64(4, 5) { |i, j| (i * 5 + j).to_f }
    a[CA_SIZE([0, 2]), nil] = UNDEF

    2.times do
      a[nil, nil].map_slab(axis: 1, data_type: :boolean) do |s|
        _ = s.to_a
        CArray.boolean(s.elements) { |i| 0 }
      end
    end
  end

end

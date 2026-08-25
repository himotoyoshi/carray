# spec_ai/test_cumsum_cumcount_rewire.rb
#
# Rewire of CArray#cumsum and CArray#cumcount to mkkernel scan kernels
# (cumsum_ki / cumcount_ki, landed in Phase D).  Restores the Ruby
# surface deleted in E.7 stat_proc retire (commit f5c7ecd) and adds
# per-axis capability (NEW vs flatten-only legacy).
#
# Dispatch contract (lib/carray/cumulative.rb):
#   - no-arg: flatten the array, return 1-D running aggregate (legacy
#     parity)
#   - single axis: return same-shape running aggregate along the axis
#     (NEW capability via Phase D kernel)
#   - multi-arg: ArgumentError (multi-axis is ambiguous)
#
# Mask semantics (matches legacy):
#   masked cells SKIP the STEP (acc unchanged) and write the *current*
#   acc to the output (= "running aggregate up to and excluding this
#   cell").  No output mask propagation.

require "test/unit"
require "carray"

class TestCumsumCumcountRewire < Test::Unit::TestCase
  # --- cumsum: no-arg = flatten (legacy parity) ---

  def test_cumsum_no_arg_1d
    a = CArray.int32(5).seq
    r = a.cumsum
    assert_equal CA_FLOAT64, r.data_type
    assert_equal [5], r.shape
    assert_equal [0.0, 1.0, 3.0, 6.0, 10.0], r.to_a
  end

  def test_cumsum_no_arg_2d_returns_1d_flatten
    a = CArray.int32(2, 3).seq
    r = a.cumsum
    assert_equal [6], r.shape  # flattened
    assert_equal [0.0, 1.0, 3.0, 6.0, 10.0, 15.0], r.to_a
  end

  # --- cumsum: per-axis (NEW capability) ---

  def test_cumsum_per_axis_returns_same_shape
    a = CArray.int32(2, 3).seq  # [[0,1,2],[3,4,5]]
    r0 = a.cumsum(axis: 0)
    assert_equal [2, 3], r0.shape
    assert_equal [[0.0, 1.0, 2.0], [3.0, 5.0, 7.0]], r0.to_a

    r1 = a.cumsum(axis: 1)
    assert_equal [[0.0, 1.0, 3.0], [3.0, 7.0, 12.0]], r1.to_a
  end

  def test_cumsum_multi_axis_raises
    a = CArray.int32(2, 3).seq
    assert_raise(ArgumentError) { a.cumsum(axis: [0, 1]) }
  end

  # --- cumsum: mask handling (legacy parity = write acc at masked) ---

  def test_cumsum_mask_writes_running_aggregate
    a = CArray.float64(5).seq
    a.mask = [0, 1, 0, 1, 0]
    # cell 0: acc=0, write 0
    # cell 1: masked, write acc=0
    # cell 2: acc=2, write 2
    # cell 3: masked, write acc=2
    # cell 4: acc=6, write 6
    assert_equal [0.0, 0.0, 2.0, 2.0, 6.0], a.cumsum.to_a
  end

  # --- cumcount: no-arg = flatten (legacy parity) ---

  def test_cumcount_no_arg_no_mask
    a = CArray.int32(5).seq
    r = a.cumcount
    assert_equal CA_INT64, r.data_type
    assert_equal [5], r.shape
    assert_equal [1, 2, 3, 4, 5], r.to_a  # all cells counted
  end

  def test_cumcount_no_arg_with_mask
    a = CArray.int32(5).seq
    a.mask = [0, 1, 0, 1, 0]
    # write count at every cell (= matches legacy)
    assert_equal [1, 1, 2, 2, 3], a.cumcount.to_a
  end

  # --- cumcount: per-axis (NEW capability) ---

  def test_cumcount_per_axis_with_mask
    a = CArray.int32(2, 3).seq
    a.mask = [[0, 0, 1], [1, 0, 0]]
    r = a.cumcount(axis: 0)
    # axis 0 scan over (2, 3):
    # col 0: [_, _] mask [0, 1] -> count [1, 1]
    # col 1: [_, _] mask [0, 0] -> count [1, 2]
    # col 2: [_, _] mask [1, 0] -> count [0, 1]
    assert_equal [[1, 1, 0], [1, 2, 1]], r.to_a
  end

  def test_cumcount_multi_axis_raises
    a = CArray.int32(2, 3).seq
    assert_raise(ArgumentError) { a.cumcount(axis: [0, 1]) }
  end

  # --- regression: empty input ---

  def test_cumsum_empty_array
    e = CArray.int32(0)
    r = e.cumsum
    assert_equal [0], r.shape
  end
end

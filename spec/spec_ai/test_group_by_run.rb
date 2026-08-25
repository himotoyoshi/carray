# frozen_string_literal: true
#
# spec_ai/test_group_by_run.rb
#
# Tests for CArray#group_by_run -- segment a 1-D array into maximal runs of
# consecutive non-masked cells and reduce each run via CACategoricalIterator.
# The mask states what separates runs; a dry (all-masked) series yields zero
# groups rather than raising.

$:.unshift(File.join(File.dirname(__FILE__), "..", "..", "lib"))

require "test/unit"
require "carray"

class TestGroupByRun < Test::Unit::TestCase

  # Rain blocks: [1,2,2,2] [2,1,2] [3,2,3,2,1] separated by zero runs.
  def rain
    CA_DOUBLE([1, 2, 2, 2, 0, 0, 0, 2, 1, 2, 0, 0, 0, 3, 2, 3, 2, 1, 0, 0, 0])
  end

  def test_per_run_sum_count_max
    grp = rain.mask_where(:le, 0).group_by_run
    assert_equal 3,                grp.ngroups
    assert_equal [0, 1, 2],        grp.labels    # 0-based run index labels
    assert_equal [7.0, 5.0, 11.0], grp.sum.to_a
    assert_equal [4, 3, 5],        grp.count.to_a
    assert_equal [2.0, 2.0, 3.0],  grp.max.to_a
  end

  def test_each_yields_each_run_as_carray
    grp  = rain.mask_where(:le, 0).group_by_run
    runs = grp.each.map(&:to_a)
    assert_equal [[1.0, 2.0, 2.0, 2.0], [2.0, 1.0, 2.0], [3.0, 2.0, 3.0, 2.0, 1.0]], runs
  end

  # The background is whatever the mask says, not a hardwired 0.
  def test_threshold_background
    grp = rain.mask_where(:lt, 2).group_by_run
    assert_equal [6.0, 2.0, 2.0, 10.0], grp.sum.to_a
  end

  def test_no_mask_is_one_run
    grp = CA_DOUBLE([1, 2, 3, 4]).group_by_run
    assert_equal 1,      grp.ngroups
    assert_equal [10.0], grp.sum.to_a
  end

  def test_single_cell_run
    grp = CA_DOUBLE([0, 5, 0]).mask_where(:le, 0).group_by_run
    assert_equal [5.0], grp.sum.to_a
    assert_equal [1],   grp.count.to_a
  end

  def test_head_and_tail_runs
    grp = CA_DOUBLE([5, 0, 5]).mask_where(:le, 0).group_by_run
    assert_equal [5.0, 5.0], grp.sum.to_a
    assert_equal [1, 1],     grp.count.to_a
  end

  # Fully masked (a dry series) -> zero groups, empty results, no raise.
  def test_all_masked_yields_zero_groups
    grp = CA_DOUBLE([1, 2, 3]).mask_where(:ge, 0).group_by_run
    assert_equal 0,  grp.ngroups
    assert_equal [], grp.sum.to_a
    assert_equal [], grp.count.to_a
  end

  def test_empty_input_yields_zero_groups
    grp = CArray.new(CA_DOUBLE, [0]).group_by_run
    assert_equal 0,  grp.ngroups
    assert_equal [], grp.sum.to_a
  end

  # Runs are defined by the flat order, so day-boundary-crossing events merge
  # once (day, 24h) data is flattened.
  def test_flatten_merges_day_boundary_run
    h = CArray.double(3, 24).fill(0)
    h[0, 22..23] = CA_DOUBLE([1, 2])
    h[1, 0..1]   = CA_DOUBLE([3, 1])
    h[1, 10..12] = CA_DOUBLE([2, 2, 1])
    grp = h.flatten.mask_where(:le, 0).group_by_run
    assert_equal [7.0, 5.0], grp.sum.to_a
    assert_equal [4, 3],     grp.count.to_a
  end

  def test_2d_rejected
    assert_raise(RuntimeError) { CArray.double(2, 3).group_by_run }
  end
end

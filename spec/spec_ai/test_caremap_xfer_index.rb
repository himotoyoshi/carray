# frozen_string_literal: true
#
# spec_ai/test_caremap_xfer_index.rb
#
# M.2: CARemap single-cell access semantics (per-element gather / scatter).
#
# Per-cell `view[i, j]` and `view[i, j] = v` dispatch through the
# CARemap xfer_index slot; we exercise that surface from ordinary Ruby
# (= the same access pattern any user would write).
#
# CARemap is only entered for N-D (N ≥ 2) same-shape CA_SIZE mapping;
# 1-D + 1-D routes upstream to CAGrid via rb_ca_scan_index.

require "test/unit"
require_relative "../../lib/carray"

class TestCARemapXferIndex < Test::Unit::TestCase

  def mk_idx (dims, values)
    a = CArray.new(CA_SIZE, dims)
    a[] = values
    a
  end

  def mk_int32 (dims, values)
    a = CArray.int32(*dims)
    a[] = values
    a
  end

  def mk_f64 (dims, values)
    a = CArray.float64(*dims)
    a[] = values
    a
  end

  # ---------------------------------------------------------------- single-cell GET

  def test_per_cell_get_2d_identity
    ref  = CArray.float64(2, 3).seq
    idx  = mk_idx([2, 3], [0, 1, 2, 3, 4, 5])
    view = ref[idx]
    2.times { |i| 3.times { |j| assert_equal ref[i, j], view[i, j] } }
  end

  def test_per_cell_get_2d_permutation
    ref  = CArray.int32(2, 3).seq + 10
    idx  = mk_idx([2, 3], [5, 3, 1, 0, 4, 2])
    view = ref[idx]
    expected = [[15, 13, 11], [10, 14, 12]]
    2.times do |i|
      3.times do |j|
        assert_equal expected[i][j], view[i, j], "view[#{i},#{j}]"
      end
    end
  end

  def test_per_cell_get_2d_repeats
    ref  = mk_int32([2, 3], [10, 20, 30, 40, 50, 60])
    idx  = mk_idx([2, 3], [0, 0, 2, 2, 4, 4])
    view = ref[idx]
    expected = [[10, 10, 30], [30, 50, 50]]
    2.times { |i| 3.times { |j| assert_equal expected[i][j], view[i, j] } }
  end

  def test_per_cell_get_3d
    ref  = CArray.float64(2, 2, 2).seq            # 0..7
    idx  = mk_idx([2, 2, 2], [7, 6, 5, 4, 3, 2, 1, 0])
    view = ref[idx]
    assert_equal [7.0, 6.0, 5.0, 4.0, 3.0, 2.0, 1.0, 0.0], view.to_a.flatten
  end

  def test_per_cell_get_through_view_ref
    base = CArray.int32(3, 4).seq                  # 0..11
    ref  = base.farray                             # 4 × 3 (CAStride view)
    idx  = mk_idx([4, 3], (0..11).to_a)            # identity over view
    view = ref[idx]
    assert_equal ref.to_a, view.to_a
  end

  # ---------------------------------------------------------------- single-cell PUT

  def test_per_cell_put_2d_identity
    ref  = CArray.float64(2, 3).fill(0.0)
    idx  = mk_idx([2, 3], [0, 1, 2, 3, 4, 5])
    view = ref[idx]
    k = 0
    2.times { |i| 3.times { |j| view[i, j] = (k += 1).to_f } }
    assert_equal [[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]], ref.to_a
  end

  def test_per_cell_put_2d_permutation
    ref  = CArray.float64(2, 3).fill(0.0)
    idx  = mk_idx([2, 3], [5, 3, 1, 0, 4, 2])
    view = ref[idx]
    vals = [[10.0, 20.0, 30.0], [40.0, 50.0, 60.0]]
    2.times { |i| 3.times { |j| view[i, j] = vals[i][j] } }
    # ref.flat[5]=10, [3]=20, [1]=30, [0]=40, [4]=50, [2]=60
    assert_equal [[40.0, 30.0, 60.0], [20.0, 50.0, 10.0]], ref.to_a
  end

  def test_per_cell_put_with_repeats_last_write_wins
    ref  = CArray.int32(2, 3).fill(0)
    idx  = mk_idx([2, 3], [2, 2, 2, 2, 4, 4])
    view = ref[idx]
    k = 10
    2.times { |i| 3.times { |j| view[i, j] = (k += 10) } }
    # ref.flat[2] gets 20,30,40,50 (last=50); ref.flat[4] = 60,70 (last=70)
    assert_equal [[0, 0, 50], [0, 70, 0]], ref.to_a
  end

  # ---------------------------------------------------------------- round trip

  def test_round_trip_get_then_put
    ref       = CArray.int32(2, 3).seq + 100        # 100..105
    idx       = mk_idx([2, 3], [5, 4, 3, 2, 1, 0])
    view      = ref[idx]
    gathered  = view.to_a
    assert_equal [[105, 104, 103], [102, 101, 100]], gathered

    ref2  = CArray.int32(2, 3).fill(0)
    view2 = ref2[idx]
    2.times { |i| 3.times { |j| view2[i, j] = gathered[i][j] } }
    assert_equal ref.to_a, ref2.to_a
  end
end

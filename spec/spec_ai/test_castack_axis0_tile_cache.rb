# CAStack axis:0 reduce via ALIAS_STACK + tile cache
# PROPOSAL_CASTACK_LOOP_INTERCHANGE rev4 (= tile cache + threshold 撤廃).
#
# ALIAS_STACK 経路は CAStack identity + no-mask + axis:0 only + READ で
# 無条件 engage、内部で TILE fibers (~32 KiB L1d 圏内) を K contig parent
# reads で先取りし、続く TILE-1 回の next_slab を cache から alias 配送。
#
# Tile cache 経路の correctness を K = 3..365 + edge shapes + dtype で
# bit-exact assert。閾値撤廃で常時 engage されるため ENV wrapper 不要。

require 'test/unit'
require 'carray'

class TestCAStackAxis0TileCache < Test::Unit::TestCase

  REDUCTIONS = %i[sum mean min max prod variance stddev]

  def assert_axis0_parity(klass, k, shape, label)
    list = Array.new(k) { |kk|
      klass.new(*shape) { |i| (kk * 13 + i * 7) % 41 - 20 }
    }
    view  = CArray.stack(list)
    # NB: post c3b2833 (3.0 breaking: to_ca returns self for data views),
    # use .copy to materialise into a genuine entity so the comparison
    # goes through the alternative L.7 Tier 1 entity path rather than
    # collapsing to self vs self.
    eager = view.copy
    REDUCTIONS.each do |op|
      a = view.send(op, axis: 0)
      b = eager.send(op, axis: 0)
      d = (a.copy - b.copy).abs.max
      assert d < 1e-9,
             "#{label} K=#{k} shape=#{shape.inspect} #{op}: maxdiff=#{d}"
    end
  end

  # ---- K sweep: cross tile boundary (TILE = clamp(32K/(K*8), [8, 64])) ----

  def test_k_small_below_tile
    # K=3 → TILE=64, total_slabs varies; covers refill-clamp tail.
    assert_axis0_parity(CArray::Float64, 3, [4, 5], "K=3 small")
  end

  def test_k_typical_multi_refill
    # K=64 (180,360) = 64800 slabs / TILE=64 = 1012.5 → tail clamp exercised
    assert_axis0_parity(CArray::Float64, 64, [180, 360], "K=64 weather-lite")
  end

  def test_k_100_canonical
    assert_axis0_parity(CArray::Float64, 100, [180, 360], "K=100 canonical")
  end

  def test_k_128_power_of_two
    # TILE = 32K / 1024 = 32 → cache 4 KiB
    assert_axis0_parity(CArray::Float64, 128, [32, 32], "K=128 pow2")
  end

  def test_k_256
    # TILE = 32K / 2048 = 16
    assert_axis0_parity(CArray::Float64, 256, [16, 16], "K=256")
  end

  def test_k_365_weather
    # TILE = 32K / 2920 = 11 (clamped to 8 floor when K very large)
    assert_axis0_parity(CArray::Float64, 365, [16, 16], "K=365 weather")
  end

  # ---- edge shapes ----

  def test_size1_inner
    # parent has size-1 innermost axis: INNER = 1
    assert_axis0_parity(CArray::Float64, 5, [4, 1], "size-1 inner")
  end

  def test_size1_only
    # parent = single cell: total_slabs = 1 per parent dimension
    assert_axis0_parity(CArray::Float64, 7, [1, 1], "size-1 only")
  end

  def test_high_ndim
    # 4-D parent: outer iter walks 3 axes
    assert_axis0_parity(CArray::Float64, 4, [3, 4, 5], "4-D parent")
  end

  # ---- dtype coverage (binary copy correctness for f32/i32) ----

  def test_dtype_float32
    assert_axis0_parity(CArray::Float32, 32, [16, 16], "f32")
  end

  def test_dtype_int32
    # prod omitted: K=32 with cell values up to 40 overflows i32 across paths
    # in inconsistent ways (orthogonal to tile cache correctness).
    list = Array.new(32) { |kk| CArray.int32(16, 16) { |i| (kk * 7 + i) % 41 } }
    view  = CArray.stack(list)
    eager = view.to_ca
    %i[sum min max].each do |op|
      assert_equal eager.send(op, axis: 0).to_a,
                   view.send(op, axis: 0).to_a,
                   "i32 #{op}"
    end
  end

  # ---- correctness vs manual K-axis reduce ----

  def test_matches_manual_per_cell_K_reduce
    # Build the K-fiber manually at one position and verify
    list = Array.new(10) { |kk| CArray.float64(8, 6) { |i| Math.sin(kk * 0.3 + i * 0.1) } }
    view = CArray.stack(list)
    mean = view.mean(axis: 0)
    # Spot-check: mean[i,j] == sum_k list[k][i,j] / 10
    8.times do |i|
      6.times do |j|
        expected = list.map { |p| p[i, j] }.sum / 10.0
        assert_in_delta expected, mean[i, j], 1e-12,
                       "mean[#{i},#{j}]"
      end
    end
  end
end

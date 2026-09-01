# spec_ai/test_sweep_cfunc_r_smoke.rb
#
# PROPOSAL_L0_AUTHOR_SURFACE §6.2 follow-up (2026-06-11) — regression
# pin for the reentrant cfunc variants (`ca_call_cfunc_M_N_r`).  These
# variants take a trailing `void *userdata` plumbed to every per-cell
# callback invocation; they unlock PROJ-style migration without the
# file-static / global plumbing that the non-`_r` variants require.

require "test/unit"
require "carray"

# Regression pin via the spec_ai-local fixture at ext_cfunc_r_smoke/ (a
# byte-for-byte mirror of the user-facing example examples/c-extensions/
# cfunc_r/).  That code is the same an external ext author would write, so
# this test exercises the public ca_call_cfunc_*_r API through the same
# pathway real consumers use.
ext_dir = File.expand_path("ext_cfunc_r_smoke", __dir__)
$LOAD_PATH.unshift(ext_dir) unless $LOAD_PATH.include?(ext_dir)
begin
  require "cfunc_r"
rescue LoadError
  warn "[skip] test_sweep_cfunc_r_smoke.rb: cfunc_r fixture not built " \
       "(run `rake build_author_surface_smoke`)"
  return
end

class TestSweepCfuncRSmoke < Test::Unit::TestCase

  # ---------- ca_call_cfunc_1_1_r ----------

  def test_1_1_userdata_scale
    a = CArray.float64(5){|i| (i + 1).to_f}
    y = CArray.demo_cfunc_r_1_1(a, 10.0)
    assert_equal [10.0, 20.0, 30.0, 40.0, 50.0], y.to_a
  end

  def test_1_1_userdata_zero_scale
    a = CArray.float64(3){|i| (i + 1).to_f}
    y = CArray.demo_cfunc_r_1_1(a, 0.0)
    assert_equal [0.0, 0.0, 0.0], y.to_a
  end

  def test_1_1_view_input
    # Slice view (= non-alias materialise path inside the engine).
    big = CArray.float64(10){|i| (i + 1).to_f}
    slc = big[3..5]   # [4.0, 5.0, 6.0]
    y = CArray.demo_cfunc_r_1_1(slc, 2.5)
    assert_equal [10.0, 12.5, 15.0], y.to_a
  end

  # ---------- ca_call_cfunc_2_2_r ----------

  def test_2_2_userdata_scale_and_threshold
    a = CArray.float64(5){|i| (i + 1).to_f}                   # [1,2,3,4,5]
    b = CArray.float64(5){|i| (i + 1).to_f * 10}              # [10,20,30,40,50]
    res, hit_count = CArray.demo_cfunc_r_2_2(a, b, 2.0, 3.5)
    # y = a * 2 → [2, 4, 6, 8, 10]
    # x = b * 2 → [20, 40, 60, 80, 100]
    assert_equal [2.0, 4.0, 6.0, 8.0, 10.0],     res[0].to_a
    assert_equal [20.0, 40.0, 60.0, 80.0, 100.0], res[1].to_a
    # hit_count: cells where a > 3.5 → indices 3, 4 → 2 hits
    assert_equal 2, hit_count
  end

  def test_2_2_hit_count_all_below_threshold
    a = CArray.float64(4){|i| (i + 1).to_f}                   # [1,2,3,4]
    b = CArray.float64(4){|i| 100.0}
    _, hit_count = CArray.demo_cfunc_r_2_2(a, b, 1.0, 100.0)
    # No a > 100.0
    assert_equal 0, hit_count
  end

  def test_2_2_hit_count_all_above_threshold
    a = CArray.float64(4){|i| (i + 10).to_f}                  # [10,11,12,13]
    b = CArray.float64(4){|i| 1.0}
    _, hit_count = CArray.demo_cfunc_r_2_2(a, b, 1.0, 5.0)
    # All 4 cells satisfy a > 5.0
    assert_equal 4, hit_count
  end

  def test_2_2_scalar_broadcast
    # scalar `a` broadcast across non-scalar `b`.  The engine's stride=0
    # branch must keep p_a fixed; userdata should still see all cells.
    a = CScalar.float64; a[0] = 2.0
    b = CArray.float64(3){|i| (i + 1).to_f * 10}
    res, hit_count = CArray.demo_cfunc_r_2_2(a, b, 5.0, 1.0)
    # y = 2.0 * 5.0 = 10.0 (broadcast to all 3 cells)
    # x = b * 5.0 = [50, 100, 150]
    assert_equal [10.0, 10.0, 10.0],    res[0].to_a
    assert_equal [50.0, 100.0, 150.0],  res[1].to_a
    # a (=2.0) > threshold(=1.0) for all 3 broadcast cells → 3 hits
    assert_equal 3, hit_count
  end
end

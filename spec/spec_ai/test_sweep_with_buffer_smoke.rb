# spec_ai/test_sweep_with_buffer_smoke.rb
#
# PROPOSAL_L0_AUTHOR_SURFACE L0.2c — formal regression pin for the
# CA_WITH_BUFFER / CA_WITH_BUFFER_WRITABLE macros and the
# rb_ca_call_with_buffer rb_ensure-protected function helper.

require "test/unit"
require "carray"

# Exercises the spec_ai-local fixture at ext_with_buffer_smoke/ (a byte-for-byte
# mirror of the user-facing example samples/c-extensions/with_buffer/).
ext_dir = File.expand_path("ext_with_buffer_smoke", __dir__)
$LOAD_PATH.unshift(ext_dir) unless $LOAD_PATH.include?(ext_dir)
begin
  require "with_buffer"
rescue LoadError
  warn "[skip] test_sweep_with_buffer_smoke.rb: with_buffer fixture not built " \
       "(run `rake build_author_surface_smoke`)"
  return
end

class TestSweepWithViewSmoke < Test::Unit::TestCase

  # ---------- CA_WITH_BUFFER (read-only) ----------

  def test_with_buffer_sum_contig
    arr = CArray.float64(5){|i| (i + 1).to_f}
    assert_in_delta 15.0, CArray.demo_with_buffer_sum_f64(arr), 1e-12
  end

  def test_with_buffer_sum_slice_materialises
    big = CArray.float64(10){|i| (i + 1).to_f}
    slc = big[3..5]   # [4.0, 5.0, 6.0]
    # Slice is a view; ca_attach materialises into scratch, ptr is the
    # scratch base.  AC1 (view transparency).
    assert_in_delta 15.0, CArray.demo_with_buffer_sum_f64(slc), 1e-12
  end

  def test_with_buffer_sum_transpose
    mat = CArray.float64(3, 4){|i, j| (i * 4 + j + 1).to_f}
    assert_in_delta 78.0, CArray.demo_with_buffer_sum_f64(mat.transpose), 1e-12
  end

  # ---------- CA_WITH_BUFFER_WRITABLE ----------

  def test_writable_scale_inplace
    arr = CArray.float64(4){|i| (i + 1).to_f}
    CArray.demo_with_buffer_scale_f64(arr, 3.0)
    assert_equal [3.0, 6.0, 9.0, 12.0], arr.to_a
  end

  def test_writable_scale_through_view
    # Writing into a view's materialised buffer must sync back to the view.
    big = CArray.float64(10){|i| (i + 1).to_f}
    slc = big[2..4]   # [3.0, 4.0, 5.0]
    CArray.demo_with_buffer_scale_f64(slc, 10.0)
    # The slice's writes propagate back to big via ca_sync.
    assert_equal 30.0, big[2]
    assert_equal 40.0, big[3]
    assert_equal 50.0, big[4]
    # Untouched cells unchanged.
    assert_equal 1.0, big[0]
    assert_equal 10.0, big[9]
  end

  # ---------- break safety (macro form, no leak via break) ----------

  def test_macro_break_no_leak
    arr = CArray.float64(10){|i| (i + 1).to_f}
    partial = CArray.demo_with_buffer_break_after_k(arr, 3)
    assert_in_delta 6.0, partial, 1e-12   # 1 + 2 + 3
    # If the prior call leaked an attach, the second call would fail or
    # double-attach.  Run the macro again to verify cleanup ran:
    sum_again = CArray.demo_with_buffer_sum_f64(arr)
    assert_in_delta 55.0, sum_again, 1e-12
  end

  # ---------- rb_ca_call_with_buffer (function form, rb_ensure) ----------

  def test_call_with_buffer_sum
    arr = CArray.float64(5){|i| (i + 1).to_f}
    assert_in_delta 15.0, CArray.demo_call_with_buffer_sum_f64(arr), 1e-12
  end

  def test_call_with_buffer_raise_runs_ensure_readonly
    # Body raises mid-iteration on a read-only view.  rb_ensure must
    # run ca_detach so the array is still usable afterwards.  No writes
    # happen because writable=false; values are preserved.
    arr = CArray.float64(5){|i| 100.0 + i}
    assert_raise(RuntimeError) do
      CArray.demo_call_with_buffer_raise(arr, 2, false)
    end
    # Array still usable (= no attach leak from the raise path).
    assert_in_delta 510.0, CArray.demo_with_buffer_sum_f64(arr), 1e-9
    assert_equal [100.0, 101.0, 102.0, 103.0, 104.0], arr.to_a
  end

  def test_call_with_buffer_raise_runs_ensure_writable_syncs_partial
    # Body writes -1.0 to cells 0..raise_index then raises.  rb_ensure
    # must call ca_sync FIRST, so the partial writes propagate back to
    # the view's storage even on raise.
    arr = CArray.float64(5){|i| 100.0 + i}
    assert_raise(RuntimeError) do
      CArray.demo_call_with_buffer_raise(arr, 2, true)
    end
    # Cells 0, 1, 2 were written (-1.0) before raise; ensure synced them.
    # Cells 3, 4 untouched.
    assert_equal -1.0,  arr[0]
    assert_equal -1.0,  arr[1]
    assert_equal -1.0,  arr[2]
    assert_equal 103.0, arr[3]
    assert_equal 104.0, arr[4]
    # Array is still usable after the partial-write raise.
    assert_in_delta 204.0, CArray.demo_with_buffer_sum_f64(arr), 1e-9
  end

  def test_call_with_buffer_raise_through_view
    # AC8: rb_ensure path with a non-alias (slice) view.  Sync back must
    # propagate partial writes to the parent.
    big = CArray.float64(10){|i| 1.0}
    slc = big[3..7]   # 5 cells
    assert_raise(RuntimeError) do
      CArray.demo_call_with_buffer_raise(slc, 1, true)
    end
    # Cells big[3], big[4] were written to -1.0 (raise at index 1 means
    # i=0, i=1 done, then raise on i=1's check), ensure synced.
    assert_equal -1.0, big[3]
    assert_equal -1.0, big[4]
    # Untouched cells remain 1.0.
    assert_equal 1.0, big[0]
    assert_equal 1.0, big[8]
    assert_equal 1.0, big[9]
  end
end

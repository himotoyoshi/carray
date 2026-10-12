# spec_ai/test_sweep_with_buffer_smoke.rb
#
# Regression pin for rb_ca_call_with_buffer: the whole array as one contig
# buffer, closed however the body is left.

require "test/unit"
require "carray"

# Exercises the spec_ai-local fixture at ext_with_buffer_smoke/ (a byte-for-byte
# mirror of the user-facing example examples/c-extensions/with_buffer/).
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

  # ---------- read-only ----------

  def test_with_buffer_sum_contig
    arr = CArray.float64(5){|i| (i + 1).to_f}
    assert_in_delta 15.0, CArray.demo_with_buffer_sum_f64(arr), 1e-12
  end

  def test_with_buffer_sum_slice_materialises
    big = CArray.float64(10){|i| (i + 1).to_f}
    slc = big[3..5]   # [4.0, 5.0, 6.0]
    # Slice is a view; it is materialised into scratch.
    assert_in_delta 15.0, CArray.demo_with_buffer_sum_f64(slc), 1e-12
  end

  def test_with_buffer_sum_transpose
    mat = CArray.float64(3, 4){|i, j| (i * 4 + j + 1).to_f}
    assert_in_delta 78.0, CArray.demo_with_buffer_sum_f64(mat.transpose), 1e-12
  end

  # ---------- writable ----------

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

  # ---------- a body that raises ----------

  def test_raise_readonly_detaches
    # Body raises mid-iteration on a read-only view.  The view must be
    # detached so the array is still usable afterwards.  No writes
    # happen because writable=false; values are preserved.
    arr = CArray.float64(5){|i| 100.0 + i}
    assert_raise(RuntimeError) do
      CArray.demo_with_buffer_raise(arr, 2, false)
    end
    # Array still usable (= no attach leak from the raise path).
    assert_in_delta 510.0, CArray.demo_with_buffer_sum_f64(arr), 1e-9
    assert_equal [100.0, 101.0, 102.0, 103.0, 104.0], arr.to_a
  end

  def test_raise_writable_syncs_partial
    # Body writes -1.0 to cells 0..raise_index then raises.  The view
    # is synced before it is detached, so the partial writes propagate back to
    # the view's storage even on raise.
    arr = CArray.float64(5){|i| 100.0 + i}
    assert_raise(RuntimeError) do
      CArray.demo_with_buffer_raise(arr, 2, true)
    end
    # Cells 0, 1, 2 were written (-1.0) before raise; they were synced.
    # Cells 3, 4 untouched.
    assert_equal -1.0,  arr[0]
    assert_equal -1.0,  arr[1]
    assert_equal -1.0,  arr[2]
    assert_equal 103.0, arr[3]
    assert_equal 104.0, arr[4]
    # Array is still usable after the partial-write raise.
    assert_in_delta 204.0, CArray.demo_with_buffer_sum_f64(arr), 1e-9
  end

  def test_raise_through_view
    # A non-alias (slice) view.  Sync back must
    # propagate partial writes to the parent.
    big = CArray.float64(10){|i| 1.0}
    slc = big[3..7]   # 5 cells
    assert_raise(RuntimeError) do
      CArray.demo_with_buffer_raise(slc, 1, true)
    end
    # Cells big[3], big[4] were written to -1.0 (raise at index 1 means
    # i=0, i=1 done, then raise on i=1's check), synced.
    assert_equal -1.0, big[3]
    assert_equal -1.0, big[4]
    # Untouched cells remain 1.0.
    assert_equal 1.0, big[0]
    assert_equal 1.0, big[8]
    assert_equal 1.0, big[9]
  end

  # ---------- a sync that raises ----------

  # A CAObject whose sync fails, as a lazily backed array's does when its
  # I/O fails.  The view is detached all the same.
  class FailingSync < CAObject
    def initialize (n)
      @src = CArray.float64(n) { 1.0 }
      super(CA_FLOAT64, [n])
    end
    def copy_data (d) ; d[] = @src ; end
    def sync_data (d) ; raise "sync failed" ; end
    def fetch_addr (a) ; @src[a] ; end
    def store_addr (a, v) ; raise "sync failed" ; end
  end

  def test_detaches_when_the_sync_raises
    arr = FailingSync.new(4)
    # The body does not raise (index 100 is past the end); the sync does.
    assert_raise_message("sync failed") do
      CArray.demo_with_buffer_raise(arr, 100, true)
    end
    assert_equal false, arr.attached?
  end
end

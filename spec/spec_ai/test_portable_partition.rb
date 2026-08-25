# PROPOSAL_PORTABLE_TEXTBOOK_SORT P9 -- partition_copy inline rewire.
#
# After P9 the value-level partition_copy stops going through
# ca_quickselect_bytes + ca_qsort_cmp comparator-pointer indirection
# and dispatches per-dtype to ca_partition_quick_<dtype> (inline cmp).
# This mirrors the P.1-P.3 rewire that sort_copy got.
#
# AC = partition contract + dtype sweep + NaN-at-end + per-axis.

require 'carray'
require 'test/unit'

P9_DTYPES = [
  [:int8,    :i8,  -100,           100,           false],
  [:uint8,   :u8,     0,           200,           false],
  [:int16,   :i16, -10_000,        10_000,        false],
  [:uint16,  :u16,        0,       60_000,        false],
  [:int32,   :i32, -1_000_000,     1_000_000,     false],
  [:uint32,  :u32,           0,    1_000_000_000, false],
  [:int64,   :i64, -1_000_000_000, 1_000_000_000, false],
  [:uint64,  :u64,            0,   1_000_000_000, false],
  [:float32, :f32, -1.0e6,         1.0e6,         true],
  [:float64, :f64, -1.0e6,         1.0e6,         true],
]

class TestPortablePartitionP9 < Test::Unit::TestCase

  # partition contract: out[kth] = kth-smallest, left <= out[kth], right >=
  def assert_partition(arr_in, out, kth, label)
    n = arr_in.length
    arr_sorted = arr_in.sort
    out_a = out.to_a

    assert_equal arr_sorted[kth], out_a[kth],
                 "#{label}: kth=#{kth} cell wrong"

    pivot = out_a[kth]
    out_a[0...kth].each_with_index do |v, i|
      assert v <= pivot, "#{label}: left[#{i}]=#{v} > pivot=#{pivot}"
    end
    out_a[(kth + 1)...n].each_with_index do |v, i|
      assert v >= pivot, "#{label}: right[#{i}]=#{v} < pivot=#{pivot}"
    end
    # Multiset preservation
    assert_equal arr_in.sort, out_a.sort,
                 "#{label}: multiset changed"
  end

  P9_DTYPES.each do |ctor, suf, lo, hi, is_float|

    # Random input, kth = quarter / half / 3-quarter.
    define_method(:"test_partition_random_#{suf}") do
      srand(20260612 + suf.hash)
      n = 256
      arr = CArray.send(ctor, n) { |i|
        is_float ? (lo + rand * (hi - lo)) : (lo + rand(hi - lo))
      }
      arr_in = arr.to_a
      [n / 4, n / 2, 3 * n / 4].each do |kth|
        out = arr.partition_copy(kth, axis: 0)
        assert_partition(arr_in, out, kth, "dtype=#{suf}, kth=#{kth}")
      end
    end

    # Already-sorted: partition should be the identity (output == input)
    # with kth correct.
    define_method(:"test_partition_already_sorted_#{suf}") do
      # i8 range is -128..127, cap at 100 to avoid overflow
      n_eff = (ctor == :int8) ? 100 : 200
      arr = CArray.send(ctor, n_eff) { |i| is_float ? i.to_f : i }
      arr_in = arr.to_a
      kth = n_eff / 2
      out = arr.partition_copy(kth, axis: 0)
      assert_partition(arr_in, out, kth, "dtype=#{suf}")
    end

    # All-equal: out[kth] is the constant, all cells equal.
    define_method(:"test_partition_all_equal_#{suf}") do
      v = is_float ? 3.0 : 7
      n = 50
      arr = CArray.send(ctor, n) { v }
      out = arr.partition_copy(n / 2, axis: 0)
      assert_equal Array.new(n, v), out.to_a, "dtype=#{suf}"
    end

    # Size sweep at small N (= insertion-base boundary).
    define_method(:"test_partition_size_sweep_#{suf}") do
      [2, 15, 16, 17, 32, 100].each do |n|
        kth = n / 2
        arr = CArray.send(ctor, n) { |i|
          v = (i * 97 + 13) % (ctor == :int8 ? 100 : 1000)
          is_float ? v.to_f : v
        }
        arr_in = arr.to_a
        out = arr.partition_copy(kth, axis: 0)
        assert_partition(arr_in, out, kth, "dtype=#{suf}, n=#{n}")
      end
    end
  end

  # ---------- NaN-at-end policy for float partition --------------------

  def test_partition_f64_nan_finite_kth
    # kth in finite region: out[kth] = kth-smallest finite, NaN at tail
    a = [3.0, Float::NAN, 1.0, 4.0, Float::NAN, 0.5, 2.0].to_ca.float64
    out = a.partition_copy(2, axis: 0)
    out_a = out.to_a
    # finite values: [0.5, 1.0, 2.0, 3.0, 4.0]; kth=2 -> 2.0
    assert_equal 2.0, out_a[2]
    # NaN should be in tail positions (out_a[5..6])
    assert out_a[5].nan? || out_a[6].nan?, "expected NaN in tail"
  end

  def test_partition_f64_nan_kth_in_nan_region
    # kth >= finite_count: cell is NaN
    a = [3.0, Float::NAN, 1.0, Float::NAN, 0.5].to_ca.float64
    # finite_count = 3 (= 3.0, 1.0, 0.5); kth=4 falls in NaN region
    out = a.partition_copy(4, axis: 0)
    assert out.to_a[4].nan?, "expected NaN at kth=4"
  end

  def test_partition_f32_nan_finite_kth
    a = [3.0, Float::NAN, 1.0, 4.0, Float::NAN, 0.5, 2.0].to_ca.float32
    out = a.partition_copy(2, axis: 0)
    assert_equal 2.0, out.to_a[2]
  end

  # ---------- per-axis ------------------------------------------------

  def test_partition_per_axis_f64
    a = CArray.float64(3, 4)
    a[0, nil] = [3.0, 1.0, 4.0, 1.0].to_ca.float64
    a[1, nil] = [5.0, 9.0, 2.0, 6.0].to_ca.float64
    a[2, nil] = [10.0, 9.0, 8.0, 7.0].to_ca.float64
    out = a.partition_copy(1, axis: 1)

    # Row 0: [1, 1, 3, 4] sorted; kth=1 -> 1.0
    assert_equal 1.0, out[0, 1].to_f
    # Row 1: [2, 5, 6, 9] sorted; kth=1 -> 5.0
    assert_equal 5.0, out[1, 1].to_f
    # Row 2: [7, 8, 9, 10] sorted; kth=1 -> 8.0
    assert_equal 8.0, out[2, 1].to_f
  end

  # ---------- negative kth (= count from end) -------------------------

  def test_partition_negative_kth_f64
    a = [3.0, 1.0, 4.0, 1.0, 5.0].to_ca.float64
    # n=5, kth=-1 = position 4 (largest)
    out = a.partition_copy(-1, axis: 0)
    assert_equal 5.0, out[4]
  end

  # ---------- adversarial input does not break --------------------------

  def test_partition_adversarial_completes
    # median-of-3 killer pattern; verifies depth-limit + escape
    n = 10_000
    half = n / 2
    src = Array.new(n)
    (0...half).each { |i| src[i] = 2 * i }
    (0...(n - half)).each { |i| src[half + i] = 2 * (n - half - 1 - i) + 1 }
    arr = CArray.float64(n) { |i| src[i].to_f }
    arr_in = arr.to_a
    kth = half
    out = arr.partition_copy(kth, axis: 0)
    assert_partition(arr_in, out, kth, "adversarial n=#{n}")
  end

end

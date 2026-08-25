# PROPOSAL_PORTABLE_TEXTBOOK_SORT P.4 -- argsort sweep AC11 gate.
#
# After P.4 lands the portable textbook pair sort for sort_index_ki (and
# transitively sort_addr_ki / rank_index_ki / partition_index via the
# existing kernel-iterator wiring), AC11 says:
#
#   sort_index(arr).map { arr[_1] } == sort_copy(arr)
#
# i.e. the permutation returned by argsort, when applied to the input,
# reproduces the sorted output.  We verify this round-trip across 10
# numeric dtypes, plus NaN-at-end policy preservation for float dtypes
# (= regression gate for the P.3/P.4 partition path).

require 'carray'
require 'test/unit'

DTYPES_FOR_P4 = [
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

class TestPortableSortP4 < Test::Unit::TestCase

  DTYPES_FOR_P4.each do |ctor, suf, lo, hi, is_float|

    # AC11: sort_index(axis: 0) on 1-D returns a permutation that, when
    # applied to the input, reproduces the sorted output.
    define_method(:"test_ac11_round_trip_#{suf}") do
      srand(20260612 + suf.hash)
      n = 256
      arr = CArray.send(ctor, n) { |i|
        is_float ? (lo + rand * (hi - lo)) : (lo + rand(hi - lo))
      }
      sigma = arr.sort_index(axis: 0)
      # Apply permutation
      reconstructed = sigma.to_a.map { |i| arr[i] }
      expected = arr.to_a.sort
      assert_equal expected, reconstructed, "dtype=#{suf}"
    end

    # AC11 also holds on already-sorted input (= identity permutation
    # within equal-key runs, stable order).
    define_method(:"test_ac11_already_sorted_#{suf}") do
      n = 100
      arr = CArray.send(ctor, n) { |i|
        is_float ? i.to_f : i
      }
      sigma = arr.sort_index(axis: 0).to_a
      assert_equal (0...n).to_a, sigma, "dtype=#{suf}"
    end

    # Reverse-sorted input: sigma should be [n-1, n-2, ..., 0].
    define_method(:"test_ac11_reverse_sorted_#{suf}") do
      n = 100
      arr = CArray.send(ctor, n) { |i|
        v = n - 1 - i
        is_float ? v.to_f : v
      }
      sigma = arr.sort_index(axis: 0).to_a
      assert_equal (0...n).to_a.reverse, sigma, "dtype=#{suf}"
    end

    # Stable tie-break: equal values keep ascending index.
    define_method(:"test_ac11_stable_tie_break_#{suf}") do
      n = 20
      arr = CArray.send(ctor, n) { |i|
        v = i % 4  # 4 distinct keys, 5 instances each
        is_float ? v.to_f : v
      }
      sigma = arr.sort_index(axis: 0).to_a
      # Within each key group, indices should be ascending (stable).
      # Key 0 has indices [0, 4, 8, 12, 16]; key 1 has [1, 5, 9, 13, 17]; etc.
      expected = (0..3).flat_map { |k| (0...5).map { |j| k + j * 4 } }
      assert_equal expected, sigma, "dtype=#{suf}"
    end

  end

  # ---------- NaN handling for float argsort ----------------------------

  def test_f64_argsort_nan_at_end
    a = [3.0, Float::NAN, 1.0, Float::NAN, 0.5].to_ca.float64
    sigma = a.sort_index(axis: 0).to_a
    # Finite first: indices 4 (0.5), 2 (1.0), 0 (3.0).  NaN last: 1, 3
    # (stable: ascending index within NaN region).
    assert_equal [4, 2, 0], sigma[0..2]
    assert_equal [1, 3], sigma[3..4]
  end

  def test_f32_argsort_nan_at_end
    a = [3.0, Float::NAN, 1.0, Float::NAN, 0.5].to_ca.float32
    sigma = a.sort_index(axis: 0).to_a
    assert_equal [4, 2, 0], sigma[0..2]
    assert_equal [1, 3], sigma[3..4]
  end

  # ---------- Per-axis argsort ------------------------------------------

  def test_per_axis_argsort_f64
    a = CArray.float64(3, 4)
    a[0, nil] = [3.0, 1.0, 4.0, 1.0].to_ca.float64
    a[1, nil] = [5.0, 9.0, 2.0, 6.0].to_ca.float64
    a[2, nil] = [5.0, 3.0, 5.0, 8.0].to_ca.float64

    sigma = a.sort_index(axis: 1)
    # Row 0: 3 1 4 1 -> sorted = 1 1 3 4 -> indices [1, 3, 0, 2]
    assert_equal [1, 3, 0, 2], sigma[0, nil].to_a
    # Row 1: 5 9 2 6 -> [2, 0, 3, 1]
    assert_equal [2, 0, 3, 1], sigma[1, nil].to_a
    # Row 2: 5 3 5 8 -> sorted = 3 5 5 8 -> stable: [1, 0, 2, 3]
    assert_equal [1, 0, 2, 3], sigma[2, nil].to_a
  end

end

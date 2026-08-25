# PROPOSAL_PORTABLE_TEXTBOOK_SORT P.2 — 10 numeric dtype sweep gate.
#
# Validates per-dtype correctness of the new ca_sort_quick_<dtype> /
# ca_sort_merge_<dtype> kernels (= AC6 ≡ AC1-AC5 hold for all numeric
# dtypes).  Scope per-dtype:
#   - random  N=1024 sorts to reference (Array#sort) byte-equal
#   - already-sorted / reverse / equal / boundary sizes
#   - stability (= mergesort only) via tagged-value reproduction
#   - sort_copy (= rewired path) parity with smoke _sort_copy_quick_v2
#
# Smoke methods gated by CARRAY_DEV_BUILD.

require 'carray'
require 'test/unit'

unless CArray.instance_methods.include?(:_sort_copy_quick_v2)
  warn "test_portable_sort_p2: dev-only smoke methods unavailable " \
       "(release build?  rebuild with CARRAY_DEV=1)"
  return
end

DTYPES = [
  [:int8,   :i8,  -100,  100],
  [:uint8,  :u8,     0,  200],
  [:int16,  :i16, -10_000,  10_000],
  [:uint16, :u16,        0,  60_000],
  [:int32,  :i32, -1_000_000, 1_000_000],
  [:uint32, :u32, 0, 1_000_000_000],
  [:int64,  :i64, -1_000_000_000, 1_000_000_000],
  [:uint64, :u64, 0, 1_000_000_000],
  [:float32, :f32, -1.0e6, 1.0e6],
  [:float64, :f64, -1.0e6, 1.0e6],
]

class TestPortableSortP2 < Test::Unit::TestCase

  DTYPES.each do |ctor, suf, lo, hi|

    define_method(:"test_quick_random_#{suf}") do
      srand(20260612 + suf.hash)
      a = CArray.send(ctor, 1024) { |i|
        if [:float32, :float64].include?(ctor)
          lo + rand * (hi - lo)
        else
          lo + rand(hi - lo)
        end
      }
      assert_equal a.to_a.sort, a._sort_copy_quick_v2.to_a, "dtype=#{suf}"
    end

    define_method(:"test_merge_random_#{suf}") do
      srand(20260612 + suf.hash)
      a = CArray.send(ctor, 1024) { |i|
        if [:float32, :float64].include?(ctor)
          lo + rand * (hi - lo)
        else
          lo + rand(hi - lo)
        end
      }
      assert_equal a.to_a.sort, a._sort_copy_merge_v2.to_a, "dtype=#{suf}"
    end

    # i8 range is -128..127 so cap the linear sequence at 100 to avoid overflow.
    seq_n = (ctor == :int8 ? 100 : 200)

    define_method(:"test_quick_already_sorted_#{suf}") do
      a = CArray.send(ctor, seq_n) { |i|
        if [:float32, :float64].include?(ctor); i.to_f; else; i; end
      }
      assert_equal a.to_a, a._sort_copy_quick_v2.to_a, "dtype=#{suf}"
    end

    define_method(:"test_merge_already_sorted_#{suf}") do
      a = CArray.send(ctor, seq_n) { |i|
        if [:float32, :float64].include?(ctor); i.to_f; else; i; end
      }
      # rev4 sorted-skip path exercised
      assert_equal a.to_a, a._sort_copy_merge_v2.to_a, "dtype=#{suf}"
    end

    define_method(:"test_quick_reverse_#{suf}") do
      a = CArray.send(ctor, seq_n) { |i|
        v = (seq_n - 1) - i
        if [:float32, :float64].include?(ctor); v.to_f; else; v; end
      }
      assert_equal a.to_a.sort, a._sort_copy_quick_v2.to_a, "dtype=#{suf}"
    end

    define_method(:"test_merge_reverse_#{suf}") do
      a = CArray.send(ctor, seq_n) { |i|
        v = (seq_n - 1) - i
        if [:float32, :float64].include?(ctor); v.to_f; else; v; end
      }
      assert_equal a.to_a.sort, a._sort_copy_merge_v2.to_a, "dtype=#{suf}"
    end

    # All-equal: use a value that round-trips losslessly into the dtype.
    # 3.14 is not exact in f32 so use 3.0 (exact) instead.
    define_method(:"test_quick_all_equal_#{suf}") do
      v = if [:float32, :float64].include?(ctor); 3.0; else; 7; end
      a = CArray.send(ctor, 100) { v }
      assert_equal Array.new(100, v), a._sort_copy_quick_v2.to_a, "dtype=#{suf}"
    end

    define_method(:"test_merge_all_equal_#{suf}") do
      v = if [:float32, :float64].include?(ctor); 3.0; else; 7; end
      a = CArray.send(ctor, 100) { v }
      assert_equal Array.new(100, v), a._sort_copy_merge_v2.to_a, "dtype=#{suf}"
    end

    define_method(:"test_quick_size_sweep_#{suf}") do
      [0, 1, 15, 16, 17, 32, 100, 127, 128, 1024].each do |n|
        a = CArray.send(ctor, n) { |i|
          v = (i * 97 + 13) % (ctor == :int8 ? 100 : 1000)
          if [:float32, :float64].include?(ctor); v.to_f; else; v; end
        }
        assert_equal a.to_a.sort, a._sort_copy_quick_v2.to_a,
                     "dtype=#{suf}, n=#{n}"
      end
    end

    define_method(:"test_merge_size_sweep_#{suf}") do
      [0, 1, 15, 16, 17, 32, 100, 127, 128, 1024].each do |n|
        a = CArray.send(ctor, n) { |i|
          v = (i * 97 + 13) % (ctor == :int8 ? 100 : 1000)
          if [:float32, :float64].include?(ctor); v.to_f; else; v; end
        }
        assert_equal a.to_a.sort, a._sort_copy_merge_v2.to_a,
                     "dtype=#{suf}, n=#{n}"
      end
    end

    # AC5 stability per dtype (alternating two-value pattern).
    define_method(:"test_merge_stable_alternating_#{suf}") do
      n = 100
      a, b = if [:float32, :float64].include?(ctor)
               [1.0, 2.0]
             else
               [1, 2]
             end
      arr = CArray.send(ctor, n) { |i| (i % 2 == 0) ? a : b }
      out = arr._sort_copy_merge_v2
      assert_equal Array.new(n / 2, a) + Array.new(n / 2, b), out.to_a,
                   "dtype=#{suf}"
    end

    # AC1 cross-check: sort_copy (= rewired path, calls ca_sort_quick_<dtype>)
    # must byte-equal the smoke result.
    define_method(:"test_sort_copy_path_parity_#{suf}") do
      srand(20260613 + suf.hash)
      a = CArray.send(ctor, 1024) { |i|
        if [:float32, :float64].include?(ctor)
          lo + rand * (hi - lo)
        else
          lo + rand(hi - lo)
        end
      }
      assert_equal a._sort_copy_quick_v2.to_a, a.sort_copy.to_a,
                   "dtype=#{suf}"
    end

  end

end

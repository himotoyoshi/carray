# cumprod/cummin/cummax per-axis migration test pin.
#
# Phase 1: lib/carray/cumulative.rb adds 3 method bridges (cumprod /
#          cummin / cummax) following the cumsum pattern. Maps `axis:`
#          kwarg to the existing MkKernel.scan _ki kernels.
# Phase 2: hand-written rb_ca_cumprod / cummin / cummax in
#          ext/carray_stat.c retired (~250 lines).
# Phase 3: cumwsum retired entirely (3.0 breaking, migration:
#          (a * w).cumsum).
#
# 3.0 breaking summary:
#   - positional (min_count, fval) args removed from all three methods
#   - object data_type dropped (scan/reduce family is ALL_NUMERIC)
#   - complex data_type dropped (deferred to family-wide phase if demand)
#   - cumwsum removed entirely (NoMethodError on call)

require 'test/unit'
require 'carray'

class TestCumulativeMigration < Test::Unit::TestCase
  # ---- cumprod flat parity ----

  def test_cumprod_flat_float
    a = CArray.float64(5).seq + 1.0
    assert_equal([1.0, 2.0, 6.0, 24.0, 120.0], a.cumprod.to_a)
  end

  def test_cumprod_flat_int_widens_to_float
    a = CArray.int32(4).seq + 1   # [1,2,3,4]
    r = a.cumprod
    assert_equal(:float64, r.data_type_name.to_sym)
    assert_equal([1.0, 2.0, 6.0, 24.0], r.to_a)
  end

  # ---- cumprod per-axis (NEW capability) ----

  def test_cumprod_axis_0_per_column
    m = CArray.float64(3, 2)
    [[1, 2], [3, 4], [5, 6]].each_with_index do |row, i|
      row.each_with_index { |v, j| m[i, j] = v.to_f }
    end
    # axis 0: cumulative along rows (per column)
    # col 0: 1, 1*3=3, 3*5=15
    # col 1: 2, 2*4=8, 8*6=48
    assert_equal([[1.0, 2.0], [3.0, 8.0], [15.0, 48.0]], m.cumprod(axis: 0).to_a)
  end

  def test_cumprod_axis_1_per_row
    m = CArray.float64(3, 2)
    [[1, 2], [3, 4], [5, 6]].each_with_index do |row, i|
      row.each_with_index { |v, j| m[i, j] = v.to_f }
    end
    # axis 1: cumulative along cols (per row)
    # row 0: 1, 1*2=2
    # row 1: 3, 3*4=12
    # row 2: 5, 5*6=30
    assert_equal([[1.0, 2.0], [3.0, 12.0], [5.0, 30.0]], m.cumprod(axis: 1).to_a)
  end

  # ---- cummin flat parity ----

  def test_cummin_flat
    a = CArray.float64(5)
    [3.0, 1.0, 4.0, 1.0, 5.0].each_with_index { |v, i| a[i] = v }
    assert_equal([3.0, 1.0, 1.0, 1.0, 1.0], a.cummin.to_a)
  end

  def test_cummin_preserves_data_type
    a = CArray.int32(5)
    [3, 1, 4, 1, 5].each_with_index { |v, i| a[i] = v }
    r = a.cummin
    assert_equal(:int32, r.data_type_name.to_sym)
    assert_equal([3, 1, 1, 1, 1], r.to_a)
  end

  # ---- cummin per-axis (NEW capability) ----

  def test_cummin_axis_0
    n = CArray.int32(3, 3)
    rows = [[5, 2, 8], [3, 6, 1], [4, 7, 9]]
    rows.each_with_index { |row, i| row.each_with_index { |v, j| n[i, j] = v } }
    # axis 0: per column
    # col 0: 5, min(5,3)=3, min(3,4)=3
    # col 1: 2, min(2,6)=2, min(2,7)=2
    # col 2: 8, min(8,1)=1, min(1,9)=1
    assert_equal([[5, 2, 8], [3, 2, 1], [3, 2, 1]], n.cummin(axis: 0).to_a)
  end

  def test_cummin_axis_1
    n = CArray.int32(3, 3)
    rows = [[5, 2, 8], [3, 6, 1], [4, 7, 9]]
    rows.each_with_index { |row, i| row.each_with_index { |v, j| n[i, j] = v } }
    # axis 1: per row
    assert_equal([[5, 2, 2], [3, 3, 1], [4, 4, 4]], n.cummin(axis: 1).to_a)
  end

  # ---- cummax flat parity ----

  def test_cummax_flat
    a = CArray.float64(5)
    [3.0, 1.0, 4.0, 1.0, 5.0].each_with_index { |v, i| a[i] = v }
    assert_equal([3.0, 3.0, 4.0, 4.0, 5.0], a.cummax.to_a)
  end

  def test_cummax_preserves_data_type
    a = CArray.int32(5)
    [3, 1, 4, 1, 5].each_with_index { |v, i| a[i] = v }
    r = a.cummax
    assert_equal(:int32, r.data_type_name.to_sym)
    assert_equal([3, 3, 4, 4, 5], r.to_a)
  end

  # ---- cummax per-axis (NEW capability) ----

  def test_cummax_axis_0
    n = CArray.int32(3, 3)
    rows = [[5, 2, 8], [3, 6, 1], [4, 7, 9]]
    rows.each_with_index { |row, i| row.each_with_index { |v, j| n[i, j] = v } }
    # axis 0: per column
    assert_equal([[5, 2, 8], [5, 6, 8], [5, 7, 9]], n.cummax(axis: 0).to_a)
  end

  # ---- negative axis ----

  def test_cumprod_negative_axis
    m = CArray.float64(3, 2)
    [[1, 2], [3, 4], [5, 6]].each_with_index do |row, i|
      row.each_with_index { |v, j| m[i, j] = v.to_f }
    end
    # axis -1 == axis 1 for 2-D
    assert_equal(m.cumprod(axis: 1).to_a, m.cumprod(axis: -1).to_a)
  end

  # ---- mask propagation ----

  def test_cumprod_mask_skip_running_acc
    # scan kernel semantics (post-2026-06-03 CLAUDE.md "3.0 breaking 副次"):
    # masked input cell -> acc unchanged, output cell carries `acc`
    # value (not sentinel 0, not UNDEF).  Shared by the identity ops
    # cumsum / cumprod / cumcount for every masked cell.  cummin / cummax
    # follow the same "hold acc" rule only AFTER the first present cell;
    # a *leading* masked cell (no running extremum yet) is UNDEF (they have
    # no identity -- see test_iterator_scan_surface / test_object_cumulative).
    a = CArray.float64(5).seq + 1.0   # [1,2,3,4,5]
    a[1] = UNDEF
    r = a.cumprod
    # idx=0: acc=1; idx=1 masked: acc still 1; idx=2: acc=1*3=3; idx=3: 3*4=12; idx=4: 12*5=60
    assert_equal([1.0, 1.0, 3.0, 12.0, 60.0], r.value.to_a)
    # mask NOT propagated to output under scan kernel semantics
    assert_equal([false, false, false, false, false], r.is_masked.to_a)
  end

  # ---- cumwsum retired (3.0 breaking) ----

  def test_cumwsum_removed
    a = CArray.float64(3).seq
    w = CArray.float64(3).seq + 1.0
    assert_raise(NoMethodError) { a.cumwsum(w) }
  end

  def test_cumwsum_migration_path
    # Migration: a.cumwsum(w) -> (a * w).cumsum
    a = CArray.float64(4).seq + 1.0   # [1,2,3,4]
    w = CArray.float64(4)
    [0.5, 1.0, 1.5, 2.0].each_with_index { |v, i| w[i] = v }
    # a*w = [0.5, 2.0, 4.5, 8.0]
    # cumsum = [0.5, 2.5, 7.0, 15.0]
    result = (a * w).cumsum
    assert_equal([0.5, 2.5, 7.0, 15.0], result.to_a)
  end

  # ---- positional (min_count, fval) args no longer accepted ----

  def test_cumprod_no_positional_args
    a = CArray.float64(3).seq + 1.0
    # legacy: a.cumprod(2, -1.0); now positional args are not accepted
    assert_raise(ArgumentError) { a.cumprod(2, -1.0) }
  end

  # ---- complex cumsum / cumprod with cmplx128 widening ----
  # mkkernel `:cumsum` and `:cumprod` use Hash output form:
  #   output: { numeric: :f64, complex: :cmplx128 }
  # so numeric source widens to f64 (int overflow safe) and complex
  # source widens to cmplx128 (= legacy hand-written rb_ca_cumsum /
  # rb_ca_cumprod parity).  Object / bool / fixlen sources fall through
  # to fallback: :raise (3.0 breaking from the old :wrap_to_f64 silent
  # cast via NUM2DBL).  Migration for object: `a.as_float64.cumsum`;
  # for bool: `a.cumcount` or `a.as_int32.cumsum`.

  def test_cumsum_complex_cmplx128_widening
    a = CArray.cmplx64(3)
    [Complex(1, 1), Complex(2, 3), Complex(4, 5)].each_with_index { |v, i| a[i] = v }
    r = a.cumsum
    # cmplx64 widens to cmplx128 (legacy parity)
    assert_equal(:cmplx128, r.data_type_name.to_sym)
    # 1+1i, 3+4i, 7+9i
    expected = [Complex(1, 1), Complex(3, 4), Complex(7, 9)]
    3.times do |i|
      assert_in_delta(expected[i].real, r[i].real, 1e-9)
      assert_in_delta(expected[i].imag, r[i].imag, 1e-9)
    end
  end

  def test_cumprod_complex_cmplx128_widening
    a = CArray.cmplx128(3)
    [Complex(1, 0), Complex(0, 1), Complex(2, 0)].each_with_index { |v, i| a[i] = v }
    r = a.cumprod
    assert_equal(:cmplx128, r.data_type_name.to_sym)
    # 1, i, 2i
    expected = [Complex(1, 0), Complex(0, 1), Complex(0, 2)]
    3.times do |i|
      assert_in_delta(expected[i].real, r[i].real, 1e-9)
      assert_in_delta(expected[i].imag, r[i].imag, 1e-9)
    end
  end

  def test_cumsum_complex_per_axis
    m = CArray.cmplx128(2, 3)
    [[Complex(1, 1), Complex(2, 2), Complex(3, 3)],
     [Complex(4, 0), Complex(0, 4), Complex(1, 1)]].each_with_index do |row, i|
      row.each_with_index { |v, j| m[i, j] = v }
    end
    r = m.cumsum(axis: 1)
    assert_equal(:cmplx128, r.data_type_name.to_sym)
    # row 0: 1+1i, 3+3i, 6+6i
    assert_in_delta(1.0, r[0, 0].real, 1e-9); assert_in_delta(1.0, r[0, 0].imag, 1e-9)
    assert_in_delta(6.0, r[0, 2].real, 1e-9); assert_in_delta(6.0, r[0, 2].imag, 1e-9)
    # row 1: 4+0i, 4+4i, 5+5i
    assert_in_delta(5.0, r[1, 2].real, 1e-9); assert_in_delta(5.0, r[1, 2].imag, 1e-9)
  end

  # ---- object / bool data_type raises explicitly ----

  def test_cumsum_object_works
    # PROPOSAL_MKKERNEL_OBJECT_DTYPE_BRANCH Phase 5a (2026-06-22):
    # cumsum / cumprod now accept CA_OBJECT via the mkkernel :object
    # branch (= rb_funcall(:+ / :*) step body).  Replaces the prior
    # DataTypeError contract.
    a = CArray.object(3)
    [1, 2, 3].each_with_index { |v, i| a[i] = v }
    assert_equal([1, 3, 6], a.cumsum.to_a)
  end

  def test_cumprod_object_works
    a = CArray.object(3)
    [1, 2, 3].each_with_index { |v, i| a[i] = v }
    assert_equal([1, 2, 6], a.cumprod.to_a)
  end

  def test_cumsum_bool_numeric
    # 3.0: boolean participates in scans/reductions as its 0/1 numeric
    # storage (cumsum = running count of true cells, u64 output).
    a = CArray.boolean(3)
    [true, false, true].each_with_index { |v, i| a[i] = v }
    r = a.cumsum
    assert_equal [1, 1, 2], r.to_a
    assert_equal CA_UINT64, r.data_type
  end
end

require 'carray'
require 'test/unit'

# Per-cell gather/scatter fast path (2026-05-30): when the descriptor engine
# layout cannot extend the innermost slab (inner axis = INDEX, or STRIDE with
# step != 1) the path used to spend most time in for_each_slab's callback +
# variable-size memcpy.  The fast path hoists the inner axis as a kind-
# specialised + bytes-typed inner loop.  This pins:
#   - all byte widths {1,2,4,8,default(16)} round-trip correctly via the
#     specialised stores
#   - inner-INDEX, inner-INDEX with duplicates, and single-element edge cases
#   - outer-INDEX layouts (= already-fast slab path) stay correct
class TestAxisDispatchPercell < Test::Unit::TestCase

  # --- inner INDEX (the optimised case) -------------------------------------

  def test_grid_inner_index_f64
    a = CArray.float64(8, 8).seq
    v = a.grid(nil, CA_INT32([0, 2, 4, 6]))   # outer STRIDE, inner INDEX
    expected = (0...8).map { |i| [0, 2, 4, 6].map { |j| (i * 8 + j).to_f } }
    assert_equal expected, v.to_ca.to_a
  end

  def test_grid_inner_index_f64_write
    a = CArray.float64(4, 8).seq
    a.grid(nil, CA_INT32([1, 3, 5, 7]))[nil, nil] = CArray.float64(4, 4) { -1.0 }
    assert_equal [0, -1, 2, -1, 4, -1, 6, -1],     a[0, nil].to_a
    assert_equal [16, -1, 18, -1, 20, -1, 22, -1], a[2, nil].to_a
  end

  def test_select_1d_bool_mask
    a = CArray.float64(10).seq
    m = CArray.int32(10).seq.gt(4)
    assert_equal [5, 6, 7, 8, 9], a[m].to_ca.to_a
  end

  def test_select_1d_bool_mask_write
    a = CArray.float64(10).seq
    a[CArray.int32(10).seq.gt(4)] = (CArray.float64(5).seq + 100.0)
    assert_equal [0, 1, 2, 3, 4, 100, 101, 102, 103, 104], a.to_a
  end

  # --- byte-width specialisation (1 / 2 / 4 / 8 / default) ------------------

  def test_inner_index_bytes_1_int8
    a = CArray.int8(2, 8).tap { |x| x[] = x.seq }
    v = a.grid(nil, CA_INT32([1, 3, 5, 7]))
    assert_equal [[1, 3, 5, 7], [9, 11, 13, 15]], v.to_ca.to_a
  end

  def test_inner_index_bytes_2_int16
    a = CArray.int16(2, 8).tap { |x| x[] = x.seq * 1000 }
    v = a.grid(nil, CA_INT32([0, 2, 4, 6]))
    assert_equal [[0, 2000, 4000, 6000], [8000, 10000, 12000, 14000]], v.to_ca.to_a
  end

  def test_inner_index_bytes_4_int32
    a = CArray.int32(2, 8).tap { |x| x[] = x.seq * 100000 }
    v = a.grid(nil, CA_INT32([1, 3, 5, 7]))
    assert_equal [[100000, 300000, 500000, 700000],
                  [900000, 1100000, 1300000, 1500000]], v.to_ca.to_a
  end

  def test_inner_index_bytes_8_float64
    a = CArray.float64(2, 8).tap { |x| x[] = x.seq * 1.5 }
    v = a.grid(nil, CA_INT32([0, 3, 6]))
    assert_equal [[0.0, 4.5, 9.0], [12.0, 16.5, 21.0]], v.to_ca.to_a
  end

  def test_inner_index_bytes_16_cmplx128
    a = CArray.cmplx128(2, 8).tap { |x| x[] = x.seq + Complex(0, 1) * x.seq }
    v = a.grid(nil, CA_INT32([0, 2, 4]))
    # default branch (bytes=16 -> memcpy) must still gather correctly
    assert_equal [Complex(0, 0),  Complex(2, 2),  Complex(4, 4)],   v[0, nil].to_a
    assert_equal [Complex(8, 8),  Complex(10, 10), Complex(12, 12)], v[1, nil].to_a
  end

  # --- outer INDEX (slab path, regression pin) ------------------------------

  def test_outer_index_inner_full_read
    a = CArray.float64(8, 4).seq
    v = a.grid(CA_INT32([0, 2, 4, 6]), nil)   # outer INDEX, inner full STRIDE
    assert_equal [[0, 1, 2, 3],     [8, 9, 10, 11],
                  [16, 17, 18, 19], [24, 25, 26, 27]], v.to_ca.to_a
  end

  def test_outer_index_inner_full_write
    a = CArray.float64(8, 4).seq
    a.grid(CA_INT32([0, 2, 4, 6]), nil)[nil, nil] = CArray.float64(4, 4) { -1.0 }
    assert_equal [-1] * 4,     a[0, nil].to_a
    assert_equal [4, 5, 6, 7], a[1, nil].to_a   # untouched
  end

  # --- edge cases -----------------------------------------------------------

  def test_single_element_inner_index
    a = CArray.float64(3, 3).seq
    v = a.grid(nil, CA_INT32([1]))            # inner count = 1
    assert_equal [[1], [4], [7]], v.to_ca.to_a
  end

  def test_2d_mask_select
    a = CArray.float64(4, 4).seq              # 2-D parent, 2-D mask
    m = a.gt(7.0)                             # selects [8..15]
    assert_equal (8..15).to_a.map(&:to_f), a[m].to_ca.to_a
  end

  def test_duplicate_index_gather
    # INDEX with duplicates: gather reads same cell multiple times.
    a = CArray.float64(2, 6).seq
    v = a.grid(nil, CA_INT32([0, 0, 1, 1]))
    assert_equal [[0, 0, 1, 1], [6, 6, 7, 7]], v.to_ca.to_a
  end
end

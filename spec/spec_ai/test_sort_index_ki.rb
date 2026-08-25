# frozen_string_literal: true
#
# SO.1 — sort_index_ki tests (PROPOSAL_SORT_AXIS.md SO.1).
#
# Pins:
#   - fiber-local σ semantics (= NumPy argsort axis= compatibility):
#     output[i_0, ..., i_{n-1}] in 0..dim[axis]-1
#   - stability (= mkkernel `:sort` kind guarantees stable via
#     (value, idx) tie-break)
#   - NaN policy `:end` (NumPy default)
#   - data_type coverage: ALL_NUMERIC (i8 / u8 / i16 / u16 / i32 / u32 / i64 /
#     u64 / f32 / f64)
#   - axis validation (negative axis / out-of-range raise)
#   - masked cells sort to masked_position: :first/:last (default :last)
#   - shape preservation (output.shape == input.shape, data_type == CA_SIZE)

require "test/unit"
require "carray"

class TestSortIndexKi < Test::Unit::TestCase

  # ---- semantics: fiber-local argsort ------------------------------------

  def test_1d_basic
    a = CArray.float64(4)
    [3.0, 1.0, 4.0, 1.5].each_with_index { |v, i| a[i] = v }
    assert_equal([1, 3, 0, 2], a.sort_index_ki(0).to_a)
  end

  def test_2d_axis0
    a = CArray.int32(2, 3)
    [[3, 1, 2], [6, 5, 4]].each_with_index do |row, i|
      row.each_with_index { |v, j| a[i, j] = v }
    end
    # Per column: col 0 = [3,6] -> [0,1], col 1 = [1,5] -> [0,1], col 2 = [2,4] -> [0,1]
    assert_equal([[0, 0, 0], [1, 1, 1]], a.sort_index_ki(0).to_a)
  end

  def test_2d_axis1
    a = CArray.int32(2, 3)
    [[3, 1, 2], [6, 5, 4]].each_with_index do |row, i|
      row.each_with_index { |v, j| a[i, j] = v }
    end
    # Per row: row 0 = [3,1,2] -> [1,2,0], row 1 = [6,5,4] -> [2,1,0]
    assert_equal([[1, 2, 0], [2, 1, 0]], a.sort_index_ki(1).to_a)
  end

  def test_2d_axis_negative
    a = CArray.int32(2, 3)
    [[3, 1, 2], [6, 5, 4]].each_with_index do |row, i|
      row.each_with_index { |v, j| a[i, j] = v }
    end
    assert_equal(a.sort_index_ki(1).to_a, a.sort_index_ki(-1).to_a)
    assert_equal(a.sort_index_ki(0).to_a, a.sort_index_ki(-2).to_a)
  end

  def test_3d_axis_middle
    a = CArray.int32(2, 3, 2).seq
    # Each (i, *, k) fiber along axis 1 has consecutive values; sorting
    # ascending preserves [0,1,2].
    σ = a.sort_index_ki(1)
    assert_equal([2, 3, 2], σ.dim.to_a)
    a.dim[0].times do |i|
      a.dim[2].times do |k|
        fiber = (0...a.dim[1]).map { |j| a[i, j, k] }
        expected = (0...fiber.size).sort_by { |idx| fiber[idx] }
        actual = (0...a.dim[1]).map { |j| σ[i, j, k] }
        assert_equal(expected, actual,
                     "fiber (i=#{i}, k=#{k}): values=#{fiber}")
      end
    end
  end

  # ---- stability ---------------------------------------------------------

  def test_stable_equal_values
    a = CArray.int32(6)
    [2, 1, 2, 1, 2, 1].each_with_index { |v, i| a[i] = v }
    # 1s appear at indices 1, 3, 5 (stable: in that order)
    # 2s appear at indices 0, 2, 4 (stable: in that order)
    assert_equal([1, 3, 5, 0, 2, 4], a.sort_index_ki(0).to_a)
  end

  def test_stable_all_equal
    a = CArray.int32(5)
    5.times { |i| a[i] = 7 }
    # All equal: stable sort preserves original order
    assert_equal([0, 1, 2, 3, 4], a.sort_index_ki(0).to_a)
  end

  # ---- NaN policy :end ---------------------------------------------------

  def test_nan_end_f64
    a = CArray.float64(5)
    [3.0, Float::NAN, 1.0, 2.0, Float::NAN].each_with_index { |v, i| a[i] = v }
    σ = a.sort_index_ki(0).to_a
    # Non-NaN cells sorted first: indices 2 (1.0), 3 (2.0), 0 (3.0)
    assert_equal([2, 3, 0], σ[0..2])
    # NaN cells at end (stable order: indices 1, 4)
    assert_equal([1, 4], σ[3..4])
  end

  def test_nan_end_f32
    a = CArray.float32(4)
    [Float::NAN, 1.0, Float::NAN, 0.5].each_with_index { |v, i| a[i] = v }
    σ = a.sort_index_ki(0).to_a
    # Non-NaN: 0.5 (idx 3), 1.0 (idx 1).  NaN: stable [0, 2]
    assert_equal([3, 1, 0, 2], σ)
  end

  # ---- data_type coverage ---------------------------------------------------

  def test_int_data_types
    src = [5, 1, 4, 1, 2]
    expected_σ = [1, 3, 4, 2, 0]   # stable: 1,1 -> idx 1,3 (in order)
    %i[int8 uint8 int16 uint16 int32 uint32 int64 uint64].each do |dt|
      a = CArray.send(dt, src.size)
      src.each_with_index { |v, i| a[i] = v }
      assert_equal(expected_σ, a.sort_index_ki(0).to_a,
                   "data_type #{dt}: σ mismatch")
    end
  end

  def test_float_data_types
    src = [3.5, 1.5, 2.5, 1.5]
    expected_σ = [1, 3, 2, 0]   # stable: 1.5, 1.5 -> idx 1, 3
    %i[float32 float64].each do |dt|
      a = CArray.send(dt, src.size)
      src.each_with_index { |v, i| a[i] = v }
      assert_equal(expected_σ, a.sort_index_ki(0).to_a,
                   "data_type #{dt}: σ mismatch")
    end
  end

  # ---- shape and data_type invariants ---------------------------------------

  def test_output_shape_equals_input
    a = CArray.int32(4, 5, 3).seq
    σ = a.sort_index_ki(1)
    assert_equal(a.dim.to_a, σ.dim.to_a)
  end

  def test_output_data_type_is_ca_size
    a = CArray.float64(10).seq
    σ = a.sort_index_ki(0)
    # CA_SIZE = CA_INT64 on 64-bit (the typical 3.0 target)
    assert_equal(CA_INT64, σ.data_type,
                 "expected CA_SIZE (= CA_INT64 on 64-bit), got #{σ.data_type}")
  end

  # ---- axis validation --------------------------------------------------

  def test_axis_out_of_range
    a = CArray.int32(3, 4).seq
    assert_raise(ArgumentError) { a.sort_index_ki(2) }
    assert_raise(ArgumentError) { a.sort_index_ki(-3) }
  end

  # ---- masked_position ----------------------------------------------------

  def test_masked_input_sorts_to_masked_position
    a = CArray.float64(5).seq
    a[2] = UNDEF
    assert_equal([0, 1, 3, 4, 2], a.sort_index_ki(0).to_a)
    assert_equal([0, 1, 3, 4, 2], a.sort_index(axis: 0).to_a)
    assert_equal([2, 0, 1, 3, 4], a.sort_index(axis: 0, masked_position: :first).to_a)
  end

  # ---- view chain transparency ------------------------------------------

  def test_view_chain_transpose
    a = CArray.int32(3, 4).seq
    tv = a.transpose                  # shape (4, 3)
    σ = tv.sort_index_ki(0)           # sort each column of transposed view
    assert_equal([4, 3], σ.dim.to_a)
    σ.dim[1].times do |j|
      fiber = (0...σ.dim[0]).map { |i| tv[i, j] }
      expected = (0...fiber.size).sort_by { |idx| fiber[idx] }
      actual = (0...σ.dim[0]).map { |i| σ[i, j] }
      assert_equal(expected, actual,
                   "column j=#{j} fiber=#{fiber}")
    end
  end

  def test_view_chain_block
    a = CArray.int32(10, 10).seq
    bv = a[2..6, 3..7]                # shape (5, 5)
    σ = bv.sort_index_ki(1)
    assert_equal([5, 5], σ.dim.to_a)
    bv.dim[0].times do |i|
      fiber = (0...bv.dim[1]).map { |j| bv[i, j] }
      expected = (0...fiber.size).sort_by { |idx| fiber[idx] }
      actual = (0...bv.dim[1]).map { |j| σ[i, j] }
      assert_equal(expected, actual, "row i=#{i}")
    end
  end

end

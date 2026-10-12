require "test/unit"
require "carray"

# A blocks / windows iterator over an array with no cells answers every
# reduction with an empty array of the reduction's type, as the core does.
class TestIteratorEmptySource < Test::Unit::TestCase

  def assert_empty_result (r, data_type, shape)
    assert_kind_of CArray, r
    assert_equal data_type, r.data_type
    assert_equal shape, r.shape
  end

  def test_blocks_over_an_empty_array
    e = CArray.float64(0)
    %w[sum mean min max variance median prod accumulate].each do |op|
      assert_empty_result e.blocks(2).send(op), :float64, [0]
    end
    assert_empty_result e.blocks(2).count_not_masked, :int64, [0]
    assert_empty_result e.blocks(2).min_addr, :int64, [0]
    lo, hi = e.blocks(2).minmax
    assert_empty_result lo, :float64, [0]
    assert_empty_result hi, :float64, [0]
    assert_empty_result CArray.float64(0, 3).blocks(2, 1).sum, :float64, [0, 3]
    assert_empty_result CArray.int32(3, 0).blocks(1, 2).mean, :float64, [3, 0]
  end

  def test_windows_over_an_empty_array
    e = CArray.float64(0)
    %w[sum mean min max variance].each do |op|
      assert_empty_result e.windows(-1..1).send(op), :float64, [0]
    end
    %w[count_not_masked count_masked elements min_index min_addr].each do |op|
      assert_empty_result e.windows(-1..1).send(op), :int64, [0]
    end
    assert_empty_result e.windows(-1..1, bounds: :nearest).median, :float64, [0]
    assert_empty_result e.windows(-1..1).wsum(CArray.float64(3) { 1 }), :float64, [0]
    assert_empty_result CArray.float64(0, 3).windows(-1..1, 0..0).sum, :float64, [0, 3]
    assert_equal 0, e.windows(-1..1).each.to_a.size
  end

  def test_windows_wider_than_a_truncated_source
    a = CArray.float64(3).seq
    assert_empty_result a.windows(-2..2, bounds: :truncate).sum, :float64, [0]
    assert_empty_result a.windows(-2..2, bounds: :truncate).min_addr, :int64, [0]
  end

  def test_an_empty_face_source_keeps_its_face
    t = CArray.time(["2024-01-01"])[CArray.boolean(1) { 0 }]
    assert_kind_of CATime, t.blocks(2).min
    assert_kind_of CATime, t.windows(-1..1).min
  end

  def test_window_offsets_are_integer_ranges
    a = CArray.float64(4).seq
    [1, nil, "x", (0..), (1.5..2)].each do |r|
      assert_raise(TypeError) { a.windows(r) }
    end
    assert_raise(ArgumentError) { a.windows(2..1) }
    # An exclusive range leaves out its end.
    assert_equal a.windows(-1..0).sum.to_a, a.windows(-1...1).sum.to_a
  end

end

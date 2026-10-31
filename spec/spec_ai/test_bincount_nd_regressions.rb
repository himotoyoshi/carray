require "test/unit"
require "carray"

# bincount_nd without a fiber axis works out the flat cell index from the labels.
class TestBincountNdRegressions < Test::Unit::TestCase

  def labels (type, *cells)
    a = CArray.new(type, [cells.size / 2, 2])
    cells.each_with_index { |v, i| a.flatten[i] = v }
    a
  end

  # --- a label type too narrow for the table -------------------------------

  def test_the_cell_does_not_depend_on_the_label_type
    %i[int8 uint8 int16 uint16 int32 uint32 int64 uint64].each { |t|
      d = CArray.new(t, [1, 3])
      d[] = 5
      h = d.bincount_nd(lengths: [6, 6, 6])
      assert_equal 1, h.counts[5, 5, 5], t.to_s
      assert_equal 1, h.total, t.to_s
    }
  end

  def test_an_int16_label_in_a_table_past_its_range
    h = labels(:int16, 200, 200).bincount_nd(lengths: [300, 300])
    assert_equal 1, h.counts[200, 200]
    assert_equal 1, h.counts.sum
  end

  def test_lengths_past_the_label_type
    h = labels(:uint8, 1, 1).bincount_nd(lengths: [300, 300])
    assert_equal 1, h.counts[1, 1]
    h = labels(:int8, 0, 0).bincount_nd(lengths: [130, 130])
    assert_equal 1, h.counts[0, 0]
  end

  def test_labels_past_the_length_in_a_narrow_type
    h = labels(:uint8, 200, 2).bincount_nd(lengths: [100, 100])
    assert_equal 1, h.overflow(axis: 0)
    assert_equal 0, h.overflow(axis: 1)
    assert_equal 1, h.full_counts[100, 2]
  end

  def test_the_largest_uint64_label_overflows_in_a_wide_table
    h = labels(:uint64, 2**64 - 1, 1).bincount_nd(lengths: [2, 2])
    assert_equal 1, h.full_counts[2, 1]
  end

  def test_weights_with_a_narrow_label_type
    d = CArray.int8(1, 3)
    d[] = 5
    h = d.bincount_nd(lengths: [6, 6, 6], weights: CA_FLOAT64([2.5]))
    assert_equal 2.5, h.counts[5, 5, 5]
  end
end

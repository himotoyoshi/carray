require "test/unit"
require "carray"

# Defects found by comparing each window and tile with the core reduction of a
# fresh array holding its cells.
class TestWindowBlockRegressions < Test::Unit::TestCase

  def masked_source
    a = CArray.float64(4) { |i| [1.0, 2.0, 3.0, 4.0][i] }
    a[1] = UNDEF
    a
  end

  # --- a constant margin is one cell each, whatever its value ---------------

  def each_constant_margin
    [0, 2, 0.5, -1].each { |fill| yield masked_source.windows(-1..1, fill_value: fill), fill }
  end

  def test_mean_counts_a_margin_cell_once
    each_constant_margin { |it, fill|
      assert_equal it.sliding_view.mean(axis: [1]).to_a, it.mean.to_a, "fill #{fill}"
    }
  end

  def test_min_count_counts_a_margin_cell_once
    each_constant_margin { |it, fill|
      assert_equal it.sliding_view.sum(axis: [1], min_count: 3).to_a,
                   it.sum(min_count: 3).to_a, "fill #{fill}"
    }
  end

  def test_a_window_of_nothing_but_margin_has_a_value
    a = masked_source
    it = a.windows(-3..-2, fill_value: 0)
    assert_equal it.sliding_view.min(axis: [1]).to_a, it.min.to_a
    assert_equal it.sliding_view.max(axis: [1]).to_a, it.max.to_a
    assert_equal 0.0, it.min[0]
  end

  def test_a_masked_cell_does_not_beat_a_margin
    a = CArray.int32(6) { |i| [1, 0, 1, 0, 1, 0][i] }
    a[1] = UNDEF
    [[-1..0, 2], [-2..0, -1]].each { |range, fill|
      it = a.windows(range, fill_value: fill)
      assert_equal it.sliding_view.min(axis: [1]).to_a, it.min.to_a, "fill #{fill}"
      assert_equal it.sliding_view.max(axis: [1]).to_a, it.max.to_a, "fill #{fill}"
    }
  end

  def test_nan_in_the_source_or_the_margin
    a = CArray.float32(1) ; a[0] = Float::NAN
    assert_equal a.windows(-1..2, fill_value: 2).sliding_view.min(axis: [1]).to_a,
                 a.windows(-1..2, fill_value: 2).min.to_a
    b = CArray.float64(3).seq
    it = b.windows(-1..1, fill_value: Float::NAN)
    assert_equal it.sliding_view.min(axis: [1]).to_a, it.min.to_a
  end

  def test_an_undefined_constant_margin_is_left_out
    it = masked_source.windows(-1..1, fill_value: UNDEF)
    assert_equal it.sliding_view.mean(axis: [1]).to_a, it.mean.to_a
    assert_equal it.sliding_view.count_not_masked(axis: [1]).to_a, it.count_not_masked.to_a
  end

  def test_a_margin_edge_of_a_masked_source_is_counted_as_masked
    it = masked_source.windows(-1..1, bounds: :nearest)
    assert_equal it.sliding_view.mean(axis: [1]).to_a, it.mean.to_a
  end

  # --- fixlen cells are not folded offset by offset -------------------------

  def fixlen
    CA_OBJECT(%w[s2 s1 s3]).to_type(:fixlen, bytes: 2)
  end

  def test_extremes_of_fixlen_windows
    assert_equal %w[s1 s1 s1], fixlen.windows(-1..1).min.to_a
    assert_equal %w[s2 s3 s3], fixlen.windows(-1..1).max.to_a
  end

  def test_a_narrow_window_refuses_as_the_core_does
    %i[sum accumulate prod mean all any].each { |op|
      kind = begin
        fixlen.public_send(op, axis: [0]) ; nil
      rescue StandardError => e
        e.class
      end
      assert_raise(kind, op.to_s) { fixlen.windows(-1..1).public_send(op) }
    }
  end

  # --- blocks over no cells -------------------------------------------------

  def test_scans_of_no_cells
    [[0], [0, 3], [3, 0]].each { |shape|
      a = CArray.float64(*shape)
      it = a.blocks(*shape.map { 2 })
      %i[cumsum cumprod cummax cummin cumcount].each { |op|
        got = it.public_send(op)
        assert_equal shape, got.shape, "#{op} #{shape}"
        assert_equal a.public_send(op).data_type, got.data_type, "#{op} #{shape}"
      }
    }
  end

  def test_count_of_a_value_over_no_cells
    [[0], [0, 3], [3, 0]].each { |shape|
      it = CArray.float64(*shape).blocks(*shape.map { 2 })
      got = it.count(1)
      assert_kind_of CArray, got
      assert_equal it.count_not_masked.shape, got.shape
      assert_equal it.count_not_masked.data_type, got.data_type
    }
  end

  def test_count_of_a_value_over_cells
    a = CArray.int32(5) { |i| [1, 1, 2, 1, 1][i] }
    assert_equal [2, 1, 1], a.blocks(2).count(1).to_a
    a[1] = UNDEF
    assert_equal [1, 1, 1], a.blocks(2).count(1).to_a
  end
end

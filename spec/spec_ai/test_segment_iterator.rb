# spec_ai/test_segment_iterator.rb
#
# CArray#segments / CASegmentIterator: reductions over consecutive segments
# of a flat sequence.  Pinned here:
#
#   * every reduction against the core reduction applied to each segment
#     directly (random offsets, masked cells, cells outside the range);
#   * the scans and map against the same per-segment reference;
#   * offsets: and lengths: naming the same segments;
#   * the construction-time snapshot, flatten-order reading of an N-D value,
#     and the payloads the fused kernels do not take (boolean, complex,
#     object, a Face), which go through the per-segment path;
#   * the refusals and the absence of an axis: form;
#   * where it sits in the family: CACategoricalIterator descends from it.

require "test/unit"
require "carray"

class TestSegmentIterator < Test::Unit::TestCase

  REDUCTIONS = %i[sum accumulate prod mean min max variance stddev
                  variancep stddevp count count_not_masked count_masked
                  median min_index max_index elements]
  SCANS = %i[cumsum cumprod cummax cummin cumcount]

  def norm (a)
    a.map { |x| x == UNDEF ? nil : (x.is_a?(Float) ? x.round(9) : x) }
  end

  def piece (v, o, c)
    o[c + 1] > o[c] ? v[o[c]...o[c + 1]] : CArray.new(v.data_type, [0])
  end

  # [value, offsets, lengths] with random segments, a random prefix and
  # suffix outside them, and sometimes a masked cell.
  def random_cases (data_type, count)
    srand(11)
    Array.new(count) do
      k    = rand(0..6)
      lens = Array.new(k) { rand(0..4) }
      pre  = rand(0..2)
      o    = [pre]
      lens.each { |l| o << o[-1] + l }
      n = o[-1] + rand(0..2)
      v = CArray.new(data_type, [n])
      v.seq!
      v = (v * 7 % 5).to_type(data_type)
      v[rand(n)] = UNDEF if n > 0 && rand < 0.5
      [v, o, lens]
    end
  end

  def test_reductions_match_the_core_per_segment
    [CA_FLOAT64, CA_INT32].each do |dt|
      random_cases(dt, 60).each do |v, o, _|
        it = v.segments(offsets: o)
        k  = o.size - 1
        REDUCTIONS.each do |op|
          exp = (0...k).map { |c| piece(v, o, c).send(op) }
          assert_equal(norm(exp), norm(it.send(op).to_a), "#{dt} #{op} #{o}")
        end
      end
    end
  end

  def test_order_statistics_weights_and_addresses
    random_cases(CA_FLOAT64, 40).each do |v, o, _|
      it = v.segments(offsets: o)
      k  = o.size - 1
      w  = CArray.float64(v.elements).seq!(1)
      assert_equal(norm((0...k).map { |c| piece(v, o, c).percentile(25) }),
                   norm(it.percentile(25).to_a))
      q = it.quantile
      (0...k).each do |c|
        exp = piece(v, o, c).quantile
        exp = exp.is_a?(CArray) ? exp.to_a : exp
        assert_equal(norm(exp.to_a), norm(q.map { |x| x[c] }), "quantile #{o} #{c}")
      end
      exp = (0...k).map { |c| o[c + 1] > o[c] ? v[o[c]...o[c + 1]].wsum(w[o[c]...o[c + 1]]) : 0.0 }
      assert_equal(norm(exp), norm(it.wsum(w).to_a))
      exp = (0...k).map { |c| o[c + 1] > o[c] ? v[o[c]...o[c + 1]].wmean(w[o[c]...o[c + 1]]) : UNDEF }
      assert_equal(norm(exp), norm(it.wmean(w).to_a))
      %i[min max].each do |op|
        exp = (0...k).map { |c|
          m = piece(v, o, c).send(:"#{op}_index")
          m == UNDEF ? nil : o[c] + m
        }
        assert_equal(exp, norm(it.send(:"#{op}_addr").to_a), "#{op}_addr #{o}")
      end
      mn, mx = it.minmax
      assert_equal(norm(it.min.to_a), norm(mn.to_a))
      assert_equal(norm(it.max.to_a), norm(mx.to_a))
    end
  end

  def test_scans_and_map_match_the_core_per_segment
    [CA_FLOAT64, CA_INT32].each do |dt|
      random_cases(dt, 40).each do |v, o, _|
        it = v.segments(offsets: o)
        k  = o.size - 1
        SCANS.each do |op|
          ref = Array.new(v.elements)
          (0...k).each do |c|
            next unless o[c + 1] > o[c]
            piece(v, o, c).send(op).to_a.each_with_index { |x, j| ref[o[c] + j] = x }
          end
          assert_equal(norm(ref), norm(it.send(op).to_a), "#{dt} #{op} #{o}")
        end
        ref = Array.new(v.elements)
        (0...k).each { |c| (o[c]...o[c + 1]).each { |i| ref[i] = v[i] == UNDEF ? nil : v[i] * 2 } }
        assert_equal(norm(ref), norm(it.map { |s| s * 2 }.to_a), "map #{o}")
      end
    end
  end

  def test_lengths_and_offsets_name_the_same_segments
    random_cases(CA_FLOAT64, 30).each do |v, _, lens|
      o = CArray.segment_offsets(lengths: lens)
      a = v.segments(lengths: lens)
      b = v.segments(offsets: o)
      assert_equal(norm(b.sum.to_a), norm(a.sum.to_a))
      assert_equal(norm(b.cumsum.to_a), norm(a.cumsum.to_a))
    end
  end

  def test_each_and_reduce
    v  = CA_FLOAT64([1, 2, 3, 4, 5])
    it = v.segments(offsets: [0, 2, 2, 5])
    assert_equal([[1.0, 2.0], [], [3.0, 4.0, 5.0]], it.each.map(&:to_a))
    assert_equal([2, 0, 3], it.reduce { |s| s.elements }.to_a)
    assert_equal([3.0, 0.0, 12.0], it.reduce(0.0) { |a, e| a + e }.to_a)
  end

  def test_sort_addr
    v = CA_FLOAT64([9, 5, 7, 1, 3, 8, 2])
    assert_equal([1, 2, 3, 4, 5], v.segments(offsets: [1, 3, 3, 6]).sort_addr.to_a)
  end

  def test_cells_outside_the_segments
    v  = CA_FLOAT64([9, 5, 7, 1, 3, 8, 2])
    it = v.segments(offsets: [1, 3, 3, 6])
    assert_equal([12.0, 0.0, 12.0], it.sum.to_a)
    assert_equal([UNDEF, 5.0, 12.0, 1.0, 4.0, 12.0, UNDEF], it.cumsum.to_a)
    assert_equal([UNDEF, -1.0, 1.0, -3.0, -1.0, 4.0, UNDEF],
                 it.map { |s| s - s.mean }.to_a)
  end

  def test_snapshot_at_construction
    v  = CA_FLOAT64([1, 2, 3, 4])
    it = v.segments(lengths: [2, 2])
    v[0] = 100
    assert_equal([3.0, 7.0], it.sum.to_a)
    assert_equal([102.0, 7.0], v.segments(lengths: [2, 2]).sum.to_a)
  end

  def test_n_dimensional_value_is_read_flat
    m = CArray.float64(2, 3).seq!
    it = m.segments(offsets: [0, 2, 6])
    assert_equal([1.0, 14.0], it.sum.to_a)
    assert_equal([2, 3], it.cumsum.shape)
  end

  def test_payloads_outside_the_fused_kernels
    b = CA_INT32([1, 0, 1, 1, 0, 0]).gt(0).segments(offsets: [0, 3, 6])
    assert_equal([false, false], b.all.to_a)
    assert_equal([true, true], b.any.to_a)
    z = CA_CMPLX128([1, 1i, 2, 3i]).segments(lengths: [2, 2])
    assert_equal([1 + 1i, 2 + 3i], z.sum.to_a)
    assert_equal([0.5 + 0.5i, 1 + 1.5i], z.mean.to_a)
    assert_equal([3r, 7], CA_OBJECT([1, 2r, 3, 4]).segments(lengths: [2, 2]).sum.to_a)
    t = CArray.time(%w[2024-01-03 2024-01-01 2024-01-05 2024-01-02], unit: :D)
    mn = t.segments(lengths: [2, 2]).min
    assert_kind_of(CATime, mn)
    assert_equal(%w[2024-01-01 2024-01-02], mn.to_a.map(&:to_s))
  end

  def test_empty_and_no_segments
    e = CArray.float64(0).segments(lengths: [])
    assert_equal([0], e.shape)
    %i[sum mean median elements].each { |op| assert_equal([], e.send(op).to_a) }
    assert_equal([], e.cumsum.to_a)
    assert_equal([], e.each.to_a)
    none = CA_FLOAT64([1, 2, 3]).segments(offsets: [1])
    assert_equal([UNDEF, UNDEF, UNDEF], none.cumsum.to_a)
    assert_equal([UNDEF, UNDEF, UNDEF], none.map { |s| s }.to_a)
  end

  def test_refusals
    v = CA_FLOAT64([1, 2, 3, 4])
    assert_raise(ArgumentError) { v.segments(offsets: [0, 5]) }
    assert_raise(ArgumentError) { v.segments(offsets: [-1, 2]) }
    assert_raise(ArgumentError) { v.segments(lengths: [3, 2]) }
    assert_raise(ArgumentError) { v.segments(offsets: [2, 1]) }
    assert_raise(ArgumentError) { v.segments }
    assert_raise(ArgumentError) { v.segments(offsets: [0, 2], lengths: [2]) }
  end

  def test_no_axis_form
    it = CA_FLOAT64([1, 2, 3, 4]).segments(lengths: [2, 2])
    [-> { it.sum(axis: 0) }, -> { it.mean(axis: 0) },
     -> { it.percentile(50, axis: 0) }, -> { it.wsum(CA_FLOAT64([1, 1, 1, 1]), axis: 0) },
     -> { it.count(axis: 0) }].each do |call|
      assert_raise(NotImplementedError) { call.call }
    end
  end

  def test_family_membership
    it = CA_FLOAT64([1, 2]).segments(lengths: [1, 1])
    assert_kind_of(CAIterator, it)
    assert_not_kind_of(CACategoricalIterator, it)
    assert_include(CACategoricalIterator.ancestors, CASegmentIterator)
    assert_equal("#<CASegmentIterator segments=2 elements=[1, 1]>", it.inspect)
  end

  def test_row_sums_from_an_indptr
    indptr  = CA_INT64([0, 2, 2, 5])
    data    = CA_FLOAT64([1, 2, 3, 4, 5])
    indices = CA_INT64([0, 2, 1, 2, 3])
    x       = CA_FLOAT64([10, 20, 30, 40])
    assert_equal([70.0, 0.0, 380.0],
                 (data * x[indices]).segments(offsets: indptr).sum.to_a)
  end

end

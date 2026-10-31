require "test/unit"
require "carray"

class TestGroupCompositePastTheCodes < Test::Unit::TestCase

  def cat (n, k)
    codes = CArray.uint8(n)
    n.times { |i| codes[i] = i % k }
    CACategorical.from_codes(codes, (0...k).map(&:to_s))
  end

  # --- a whole array grouped by several slots, past what uint8 codes hold ---

  def test_a_reduction_when_the_groups_outnumber_the_codes
    c = cat(40, 20)
    v = CArray.float64(40, 40).seq!
    r = v[c, c].sum(axis: :group)
    assert_equal [20, 20], r.shape
    assert_equal v.sum, r.sum
    # cells (i, j) with i % 20 == 1 and j % 20 == 2
    assert_equal [v[1, 2], v[1, 22], v[21, 2], v[21, 22]].sum, r[1, 2]
  end

  def test_each_reduction_past_the_codes
    c = cat(20, 20)
    v = CArray.float64(20, 20).seq!
    assert_equal v[3, 4], v[c, c].mean(axis: :group)[3, 4]
    assert_equal v[3, 4], v[c, c].min(axis: :group)[3, 4]
    assert_equal v[3, 4], v[c, c].median(axis: :group)[3, 4]
    assert_equal 1, v[c, c].count(axis: :group)[3, 4]
  end

  def test_exactly_as_many_groups_as_the_codes_refuse
    c = CACategorical.from_codes(CA_UINT8([0, 1]), %w[a b c d])
    v = CArray.float64(2, 2, 2, 2).seq!
    r = v[c, c, c, c].sum(axis: :group)
    assert_equal [4, 4, 4, 4], r.shape
    assert_equal v.sum, r.sum
  end

  def test_excluded_and_masked_cells_past_the_codes
    keys = CArray.object(20) { |i| i == 3 ? "zz" : (i % 20).to_s }
    c = keys.categorize(labels: (0...20).map(&:to_s))
    v = CArray.float64(20, 20).seq!
    v[1, 1] = UNDEF
    r = v[c, c]
    assert_equal 19 * 19 - 1, r.count(axis: :group).sum
    assert_equal UNDEF, r.mean(axis: :group)[3, 4]
    assert_equal UNDEF, r.mean(axis: :group)[1, 1]
    assert_equal 0.0, r.sum(axis: :group)[1, 1]
  end

  def test_a_payload_the_engine_does_not_read_past_the_codes
    c = cat(20, 20)
    o = CArray.object(20, 20) { |i, j| i * 100 + j }
    assert_equal 304, o[c, c].sum(axis: :group)[3, 4]
    z = CArray.cmplx128(20, 20).seq!
    assert_equal z[3, 4], z[c, c].sum(axis: :group)[3, 4]
  end

  def test_a_running_statistic_past_the_codes
    c = cat(20, 20)
    v = CArray.float64(20, 20).seq!
    assert_equal v.to_a, v[c, c].cumsum(axis: :group).to_a
  end
end

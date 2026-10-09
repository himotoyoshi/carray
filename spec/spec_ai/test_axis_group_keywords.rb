require "test/unit"
require "carray"

# A group reduction takes min_count: and fill_value: as a core reduction
# does, refuses any other keyword, and the plain reduction (no :group in
# axis:) passes every keyword through.

class TestAxisGroupKeywords < Test::Unit::TestCase

  def setup
    @h = CA_FLOAT64([[1.0], [2.0], [3.0], [4.0]])
    @h[0, 0] = UNDEF
    @g = @h[@h.axis_group(CA_INT32([0, 0, 1, 1]).categorize, nil)]
  end

  def test_min_count_and_fill_value_on_a_group_reduction
    [:sum, :mean, :min, :max, :median].each do |op|
      r = @g.send(op, axis: :group, min_count: 2)
      assert_equal true, r[0, 0] == UNDEF || r.mask[0, 0], op.to_s
      assert_equal(-9.0, @g.send(op, axis: :group, min_count: 2, fill_value: -9)[0, 0], op.to_s)
      assert_not_equal UNDEF, @g.send(op, axis: :group, min_count: 1)[0, 0], op.to_s
    end
    assert_equal [UNDEF, 3.0], @g.quantile(axis: :group, min_count: 2)[0].to_a.flatten
  end

  def test_unknown_keywords_are_refused
    assert_raise(ArgumentError) { @g.sum(axis: :group, foo: 1) }
    assert_raise(ArgumentError) { @g.percentile(50, axis: :group, method: :lower) }
    assert_raise(TypeError)     { @g.mean(axis: :group, min_count: 1.5) }
    assert_raise(ArgumentError) { @g.mean(axis: :group, min_count: -1) }
  end

  def test_plain_reduction_passes_keywords_through
    assert_equal UNDEF, @g.sum(min_count: 9)
    assert_equal @h.mean(axis: 0, min_count: 4).to_a, @g.mean(axis: 0, min_count: 4).to_a
    assert_equal @h.percentile(50, method: :lower), @g.percentile(50, method: :lower)
  end

end

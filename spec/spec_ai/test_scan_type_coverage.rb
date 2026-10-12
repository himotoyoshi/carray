require "test/unit"
require "carray"

# cumcount reads only the mask, so it answers for every data type without
# converting the values.
class TestScanTypeCoverage < Test::Unit::TestCase

  def with_hole (a)
    a[1] = UNDEF
    a
  end

  def test_cumcount_of_any_data_type
    expect = [1, 1, 2]
    [CA_OBJECT(%w[a b c]), CA_OBJECT([1, nil, 3]), CA_CMPLX128([1, 2, 3]),
     CA_BOOLEAN([1, 0, 1]), CArray.new(:fixlen, [3], bytes: 2),
     CA_INT32([1, 2, 3])].each do |a|
      got = with_hole(a).cumcount
      assert_equal :int64, got.data_type, a.data_type.to_s
      assert_equal expect, got.to_a, a.data_type.to_s
    end
  end

  def test_cumcount_along_an_axis
    o = CA_OBJECT([%w[a b c], %w[d e f]])
    o[0, 1] = UNDEF
    i = CArray.int32(2, 3) { 0 }
    i[0, 1] = UNDEF
    [0, 1, -1].each do |ax|
      assert_equal i.cumcount(axis: ax).to_a, o.cumcount(axis: ax).to_a, "axis #{ax}"
    end
    assert_raise(ArgumentError) { o.cumcount(axis: 2) }
  end

  def test_cumcount_of_a_face
    t = CArray.int64(3) { |i| i }.time(unit: :s)
    assert_equal [1, 2, 3], t.cumcount.to_a
  end
end

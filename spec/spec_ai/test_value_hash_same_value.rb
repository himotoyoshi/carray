require "test/unit"
require "carray"

# The value-hash family decides whether two cells hold the same value: every
# NaN is one value, and -0.0 is the same value as +0.0.  Every member counts
# the distinct values the same way, for each type the family takes.

class TestValueHashSameValue < Test::Unit::TestCase

  N = Float::NAN

  # Three distinct values: the zeros, the NaNs (of either sign) and 1.
  REALS = [-0.0, N, 1.0, 0.0, N, -N, 1.0, -0.0]

  def arrays
    out = {}
    [CA_FLOAT64, CA_FLOAT32].each do |t|
      a = CArray.new(t, [REALS.size])
      a[] = REALS
      out[CArray.data_type_name(t)] = a
    end
    [CA_CMPLX128, CA_CMPLX64].each do |t|
      a = CArray.new(t, [REALS.size])
      a[] = REALS.map { |x| Complex(x, x) }
      out[CArray.data_type_name(t)] = a
    end
    out["object"] = CA_OBJECT(REALS)
    out["object complex"] = CA_OBJECT(REALS.map { |x| Complex(x, x) })
    out
  end

  def size_of (x)
    x.is_a?(CArray) ? x.elements : x.size
  end

  def test_every_member_finds_three_values
    arrays.each do |name, a|
      assert_equal 3, a.nunique, "#{name} nunique"
      assert_equal 3, a.unique.elements, "#{name} unique"
      assert_equal 3, a.mask_duplicates.count_not_masked, "#{name} mask_duplicates"
      next if a.complex?
      assert_equal 3, a.value_counts[0].elements, "#{name} value_counts"
      assert_equal 3, size_of(a.categorize.labels), "#{name} categorize"
    end
  end

  def test_membership_and_set_operations_match_by_value
    [CA_FLOAT64, CA_FLOAT32].each do |t|
      a = CArray.new(t, [REALS.size])
      a[] = REALS
      set = CArray.new(t, [2])
      set[] = [0.0, N]
      label = CArray.data_type_name(t)
      assert_equal [true, true, false, true, true, true, false, true], a.is_in(set).to_a, label
      assert_equal 2, a.intersection(set).elements, "#{label} intersection"
      assert_equal 1, a.difference(set).elements, "#{label} difference"
      assert_equal 3, a.union(set).elements, "#{label} union"
    end
  end
end

require "test/unit"
require "carray"

# The value-hash family on complex arrays: values are distinct by value, every
# NaN is one value and -0.0 equals 0.0 in each component. Members that list
# values in order refuse, since complex numbers have no order.
class TestComplexValueHash < Test::Unit::TestCase

  NAN = Float::NAN

  def sample (dt)
    a = CArray.new(dt, [7])
    a[] = [1, Complex(2, 1), 1, Complex(-0.0, 0), 0, Complex(NAN, 0), Complex(NAN, 1)]
    a[6] = UNDEF
    a
  end

  def each_type (&block)
    [:cmplx128, :cmplx64].each { |dt| block.call(sample(dt), dt) }
  end

  def test_unique_and_counts
    each_type do |a, dt|
      u = a.unique
      assert_equal dt, u.data_type_name.to_sym
      assert_equal [1, Complex(2, 1), 0], u.to_a[0, 3]
      assert u.to_a[3].real.nan?
      assert_equal 4, a.nunique
      assert_equal [2, 1, 2, 1], a.value_counts[1].to_a
      assert_equal [false, false, true, false, true, false, true], a.mask_duplicates.is_masked.to_a
      assert_equal [true, false, true, true, true, false, false], a.is_mode.to_a
    end
  end

  def test_lookup_and_set_operations
    each_type do |a, dt|
      assert_equal [true, true, true, false, false, false, UNDEF], a.is_in([1, Complex(2, 1)]).to_a
      assert_equal [false, false, false, true, true, false, UNDEF], a.is_in(CA_INT32([0])).to_a
      other = CArray.new(dt, [2]); other[] = [1, 5]
      assert_equal [1], a.intersection(other).to_a
      assert_equal 3, a.difference(other).elements
      query = CArray.new(dt, [3]); query[] = [Complex(2, 1), 0, 7]
      assert_equal [UNDEF, 0, UNDEF, 1, 1, UNDEF, UNDEF], a.locate_addr(query).to_a
    end
  end

  def test_categorize_and_group_by
    each_type do |a, dt|
      c = a.categorize
      assert_equal [0, 1, 0, 2, 2, 3, UNDEF], c.codes.to_a
      assert_equal [1, Complex(2, 1), 0], c.labels.to_a[0, 3]
      df = CAFrame.new("k" => a, "v" => CA_INT64((0...7).to_a))
      assert_equal [2, 1, 7, 5], df.group_by("k").sum["v"].to_a
    end
  end

  def test_members_that_need_an_order_refuse
    each_type do |a, dt|
      [-> { a.unique(sort: true) }, -> { a.mode },
       -> { a.categorize(sort_labels: true) }].each do |op|
        e = assert_raise(CArray::DataTypeError) { op.call }
        assert_match(/a #{dt} value has no order/, e.message)
      end
    end
  end
end

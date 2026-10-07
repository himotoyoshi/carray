require "test/unit"
require "carray"

# A reduction of a lazy expression answers what the same reduction of the
# made-whole array answers when there is nothing to fold, and when
# min_count asks for more cells than there are.
class TestLazyReduceEmpty < Test::Unit::TestCase

  def lazy_of (a)
    a.data_type == :object ? a.lazy + 0 : a.lazy * 1
  end

  def assert_matches_eager (a, op, *args, **kw)
    eager = a.send(op, *args, **kw)
    lazy  = lazy_of(a).send(op, *args, **kw)
    if eager.equal?(UNDEF)
      assert_same UNDEF, lazy, "#{a.data_type} #{op} #{kw}"
    else
      assert_equal eager, lazy, "#{a.data_type} #{op} #{kw}"
    end
  end

  %i[float64 int32 object].each do |dt|
    %i[sum prod mean min max variance stddev].each do |op|
      define_method("test_empty_#{dt}_#{op}") do
        assert_matches_eager CArray.new(dt, [0]), op
      end
    end

    define_method("test_min_count_above_cell_count_#{dt}") do
      a = CArray.new(dt, [3])
      a[] = dt == :object ? CA_OBJECT([1, 2, 3]) : CA_INT32([1, 2, 3])
      %i[sum mean min max].each do |op|
        assert_matches_eager a, op, min_count: 10
        assert_matches_eager a, op, min_count: 3
      end
    end
  end
end

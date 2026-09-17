# count(v) on an object array.
#
# The value-comparison count kernel was declared over ALL_NUMERIC only, so
# an object array -- the one data_type that can hold the values people most
# want to count, strings among them -- raised
# "count_equal_ki: source data_type :object not supported".  The dispatcher
# comment said as much, ending "Extend count_equal_ki if demand returns."
#
# The object lane compares with rb_equal, which is Ruby ==: 1 and 1.0 count
# as the same value there, as they do everywhere else in Ruby.

require 'test/unit'
require 'carray'

class TestCountObject < Test::Unit::TestCase

  def test_counts_a_string
    a = CA_OBJECT(%w[a b a c a])
    assert_equal 3, a.count("a")
    assert_equal 1, a.count("b")
    assert_equal 0, a.count("z")
  end

  def test_counts_a_number_by_ruby_equality
    a = CA_OBJECT([1, 2, 1])
    assert_equal 2, a.count(1)
    assert_equal 2, a.count(1.0)      # 1 == 1.0
    assert_equal 1, a.count(2)
  end

  def test_counts_nil_and_other_plain_objects
    assert_equal 2, CA_OBJECT([nil, 1, nil]).count(nil)
    assert_equal 1, CA_OBJECT([:a, :b, :c]).count(:b)
  end

  # true / false are the boolean array's own domain and are refused there,
  # but in an object array they are ordinary stored values.
  def test_counts_true_and_false_in_an_object_array
    a = CA_OBJECT([true, false, true])
    assert_equal 2, a.count(true)
    assert_equal 1, a.count(false)
  end

  def test_a_numeric_array_still_refuses_true
    assert_raise(TypeError) { CA_INT32([1, 2]).count(true) }
  end

  def test_along_an_axis
    a = CA_OBJECT([%w[a b], %w[a a]])
    assert_equal [1, 2], a.count("a", axis: 1).to_a
  end

  def test_masked_cells_do_not_count
    a = CA_OBJECT(%w[a b a])
    a[0] = UNDEF
    assert_equal 1, a.count("a")
    assert_equal 2, a.count            # unmasked cells
    assert_equal 1, a.count(UNDEF)     # mask-state count
  end

  def test_empty_counts_zero
    assert_equal 0, CA_OBJECT([]).count("a")
  end

  # The storage under a CAString is an object array, and counts as one.
  # The Face itself is still gated at the COMPARABLE flag, which is a
  # separate question from whether the kernel can do the work.
  def test_the_object_storage_under_a_string_face
    assert_equal 2, CArray.string(%w[a b a]).parent.count("a")
  end

  def test_other_data_types_are_untouched
    assert_equal 2, CA_INT32([1, 2, 1]).count(1)
    assert_equal 2, CArray.boolean(3) { |i| i != 1 }.count(true)
    assert_raise(CArray::DataTypeError) do
      x = CArray.new(CA_FIXLEN, [3], bytes: 4)
      %w[a b a].each_with_index { |v, i| x[i] = v }
      x.count("a")
    end
  end

end

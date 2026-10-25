# spec_ai/test_cscalar_index.rb
#
# A CScalar is one cell, so it takes no index.  s[] and s[0] both read
# the value, s[] = v and s[0] = v both write it; any other index (another
# integer, a range, nil, an index array, a sigil) is refused.

require "test/unit"
require "carray"

class TestCScalarIndex < Test::Unit::TestCase

  def scalar
    CScalar.float64.tap { |s| s[0] = 2.5 }
  end

  def test_empty_index_reads_the_value
    assert_equal 2.5, scalar[]
  end

  def test_zero_reads_the_value
    assert_equal 2.5, scalar[0]
  end

  def test_masked_value_reads_undef
    s = scalar
    s[] = UNDEF
    assert_equal UNDEF, s[]
    assert_equal UNDEF, s[0]
  end

  def test_both_forms_write
    s = scalar
    s[] = 3.0
    assert_equal 3.0, s[0]
    s[0] = 4.0
    assert_equal 4.0, s[]
  end

  def test_other_reads_are_refused
    s = scalar
    [[1], [5], [-1], [0..0], [nil], [0, 0], [[0]], [:_], [CA_INT32([0])]].each do |idx|
      e = assert_raise(ArgumentError, idx.inspect) { s[*idx] }
      assert_match(/CScalar/, e.message)
    end
  end

  def test_other_writes_are_refused
    s = scalar
    [[1], [-1], [0..0], [nil], [0, 0], [[0]], [:_]].each do |idx|
      assert_raise(ArgumentError, idx.inspect) { s[*idx] = 1.0 }
    end
    assert_equal 2.5, s[]
  end

  def test_meshgrid_takes_a_scalar_axis
    a = CA_INT32([1, 2])
    x, y = CArray.meshgrid(a, scalar)
    assert_equal [[1, 2]], x.to_a
    assert_equal [[2.5, 2.5]], y.to_a
  end
end

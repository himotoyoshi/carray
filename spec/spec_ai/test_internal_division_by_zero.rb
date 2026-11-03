require "test/unit"
require "carray"

# Divisors the library takes from shapes, widths, steps and counts.  On ARM
# an integer division by zero gives 0 and the code below went on (often to
# a later check that refused it, sometimes to a wrong answer); on x86 it
# stops the process with SIGFPE.  Each case here names an input that used
# to reach such a division.

class TestInternalDivisionByZero < Test::Unit::TestCase

  def test_wrap_readonly_of_a_string_as_fixlen_is_refused
    e = assert_raise(ArgumentError) { CArray.wrap_readonly("abc", CA_FIXLEN) }
    assert_match(/bytes: of 1 or more/, e.message)
    assert_equal [25185, 25699], CArray.wrap_readonly("abcd", CA_INT16).to_a
  end

  def test_window_with_a_zero_step_is_refused
    a = CArray.int32(5).seq
    [[1..3, 0], [nil, 0]].each do |r|
      e = assert_raise(ArgumentError, r.inspect) { a.window(r) }
      assert_match(/step should not be 0/, e.message)
    end
    [[0..2, 0.5], 0.step(2, 0.5), (0.0..2.0).step(0.5)].each do |r|
      assert_raise(TypeError, r.inspect) { a.window(r) }
    end
    assert_equal [1, 2, 3], a.window([1..3, 1]).to_a
  end

  def test_weights_broadcast_over_a_zero_length_axis
    w3 = CArray.float64(3) { 1 }
    assert_equal [], CArray.float64(3, 0).wsum(w3, axis: 0).to_a
    assert_equal [], CArray.int32(3, 0).wsum(w3, axis: 0).to_a
    assert_equal [0.0, 0.0, 0.0], CArray.float64(0, 3).wsum(CArray.float64(0), axis: 0).to_a
    assert_equal [UNDEF] * 3, CArray.float64(3, 0).wmean(CArray.float64(0), axis: 1).to_a
    assert_equal [10.0, 13.0], CArray.float64(3, 2).seq.wsum(CArray.float64(3).seq, axis: 0).to_a
  end

  def test_view_over_a_stack_of_empty_parents
    s = CArray.stack([CArray.int32(0), CArray.int32(0)])
    assert_equal 0, s[:_, nil, nil].sum
    assert_equal [], s.flatten.sort.to_a
    assert_equal [], s[nil, nil].sort.to_a
  end

  def test_reshape_with_no_axes_is_refused
    e = assert_raise(ArgumentError) { CArray.int32(3).seq[1..1].reshape }
    assert_match(/at least one axis/, e.message)
  end

  def test_drop_axis_keeps_one_axis_when_every_axis_has_size_one
    x = CArray.int32(1, 1) { 5 }.drop_axis
    assert_equal [1], x.shape
    assert_equal [5], x.to_a
    assert_equal [3, 2], CArray.int32(3, 1, 2).drop_axis.shape
  end

  def test_key_window_interval_must_be_positive
    keys = CArray.int64(2).seq
    groups = CArray.int64(2)
    [0, -1].each do |iv|
      assert_raise(ArgumentError, iv.to_s) do
        CArray.__find_key_window_row_ranges__(keys, groups, 1, 1, false, false, iv, 1, nil)
      end
    end
  end

  def test_reduce_view_count_must_be_positive
    omit "dev build only" unless CArray.respond_to?(:t1_make_reduce)
    assert_raise(ArgumentError) { CArray.t1_make_reduce(CArray.boolean(4), 0, 0) }
  end

end

require "test/unit"
require "carray"

# Error messages name what the caller wrote and the method the caller called.
class TestErrorMessageWording < Test::Unit::TestCase

  def message_of
    yield
    flunk "expected an exception"
  rescue StandardError => e
    e.message
  end

  def test_out_of_range_index_reports_the_index_given
    v = CArray.int32(10).seq
    assert_match(/\( -20 <=> 0\.\.9 \)/, message_of { v[-20] })
    assert_match(/\( -20 <=> 0\.\.9 \)/, message_of { v[[-20]] })
  end

  def test_positional_axis_hint_names_the_method_called
    msg = message_of { CArray.float64(3).count(1.0, 0) }
    assert_match(/a\.count\(axis: 0\)/, msg)
    assert_no_match(/count_equal/, msg)
  end

  def test_unsupported_type_is_named
    c = CArray.cmplx128(3)
    assert_match(/:cmplx128/, message_of { c.median })
    assert_match(/:cmplx128/, message_of { c.percentile(50) })
    assert_match(/:cmplx128/, message_of { c.partition_copy(1) })
  end

  def test_internal_labels_do_not_leak
    assert_match(/\Atake_along_axis: index 5/,
                 message_of { CArray.int32(2, 2).take_along_axis(CArray.int64(2, 2) { 5 }, axis: 1) })
    assert_no_match(/W-A3/, message_of { CArray.float64(2, 3).wsum(CArray.float64(3, 2), axis: 0) })
    assert_match(/data_type id 999\b/, message_of { CArray.int32(2).to_type(999) })
  end

end

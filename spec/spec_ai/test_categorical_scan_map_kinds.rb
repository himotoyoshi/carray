require "test/unit"
require "carray"

# The running statistics (cum*) and #map of the categorical iterator answer for
# every value the core answers for: an N-D value classified along an axis
# (axis:), a Face value, and the data types the scan kernel does not answer in
# the core's type.
class TestCategoricalScanMapKinds < Test::Unit::TestCase

  def setup
    keys = CA_INT32([1, 2, 1, 2, 1, 3])
    keys[3] = UNDEF
    @cat = keys.categorize
  end

  def surface (a)
    a.to_a.flatten.map { |v| v.equal?(UNDEF) ? v : v.to_s }
  end

  # ---- N-D value, classified along an axis -------------------------------

  def test_scan_along_axis_0
    w = CArray.float64(6, 2).seq
    it = w.group_by_category(@cat)
    assert_equal [[0.0, 1.0], [2.0, 3.0], [4.0, 6.0], [UNDEF, UNDEF], [12.0, 15.0], [10.0, 11.0]],
                 it.cumsum(axis: 0).to_a
    assert_equal [[1, 1], [1, 1], [2, 2], [UNDEF, UNDEF], [3, 3], [1, 1]],
                 it.cumcount(axis: 0).to_a
  end

  def test_scan_along_a_later_axis
    w = CArray.float64(6, 2).seq.transpose.copy        # (2, 6), classified along axis 1
    it = w.group_by_category(@cat)
    expected = [[0.0, 2.0, 4.0, UNDEF, 12.0, 10.0], [1.0, 3.0, 6.0, UNDEF, 15.0, 11.0]]
    assert_equal expected, it.cumsum(axis: 1).to_a
    assert_equal expected, it.cumsum(axis: -1).to_a
  end

  def test_map_along_axis
    w = CArray.float64(6, 2).seq
    out = w.group_by_category(@cat).map(axis: 0) { |g| g - g.mean }
    assert_equal [[-4.5, -3.5], [-0.5, 0.5], [-0.5, 0.5], [UNDEF, UNDEF], [3.5, 4.5], [-0.5, 0.5]],
                 out.to_a
  end

  def test_axis_needs_the_categorical_along_it
    it = CArray.float64(6, 2).seq.group_by_category(@cat)
    err = assert_raise(ArgumentError) { it.cumsum(axis: 1) }
    assert_match(/positions along axis 1/, err.message)
    assert_raise(ArgumentError) { it.map(axis: 1) { |g| g } }
  end

  # ---- Face values -------------------------------------------------------

  def times
    CArray.time(%w[2024-01-03 2024-01-01 2024-01-02 2024-01-04 2024-01-01 2024-01-09], unit: :D)
  end

  def test_time_running_extremum_is_a_time
    out = times.group_by_category(@cat).cummin
    assert_kind_of CATime, out
    assert_equal ["2024-01-03", "2024-01-01", "2024-01-02", UNDEF, "2024-01-01", "2024-01-09"],
                 surface(out)
  end

  def test_time_running_extremum_along_an_axis
    t = CArray.time((1..12).map { |i| "2024-01-%02d" % (13 - i) }, unit: :D).reshape(6, 2)
    out = t.group_by_category(@cat).cummax(axis: 0)
    assert_kind_of CATime, out
    assert_equal ["2024-01-12", "2024-01-11", "2024-01-10", "2024-01-09",
                  "2024-01-12", "2024-01-11", UNDEF, UNDEF,
                  "2024-01-12", "2024-01-11", "2024-01-02", "2024-01-01"], surface(out)
  end

  def test_time_running_sum_is_refused_as_the_core_refuses_it
    core = assert_raise(TypeError) { times.cumsum }
    err  = assert_raise(TypeError) { times.group_by_category(@cat).cumsum }
    assert_equal core.message, err.message
  end

  def test_timedelta_running_sum_is_a_timedelta
    out = CA_INT64([1, 2, 3, 4, 5, 6]).timedelta(unit: :D).group_by_category(@cat).cumsum
    assert_kind_of CATimedelta, out
    assert_equal ["1D", "2D", "4D", UNDEF, "9D", "6D"], surface(out)
  end

  def test_running_count_of_a_face
    assert_equal [1, 1, 2, UNDEF, 3, 1], times.group_by_category(@cat).cumcount.to_a
  end

  def test_map_of_a_time_is_a_time
    out = times.group_by_category(@cat).map { |s| s.min }
    assert_kind_of CATime, out
    assert_equal ["2024-01-01", "2024-01-01", "2024-01-01", UNDEF, "2024-01-01", "2024-01-09"],
                 surface(out)
  end

  def test_map_of_a_read_only_face_gives_its_surface_values
    s = CArray.const_string(%w[b a c d e f]).group_by_category(@cat).map { |x| x }
    assert_equal CA_OBJECT, s.data_type
    assert_equal ["b", "a", "c", UNDEF, "e", "f"], s.to_a
  end

  def test_empty_face
    empty = times[0...0]
    out = empty.group_by_category(CA_INT32([]).categorize).cummin
    assert_kind_of CATime, out
    assert_equal 0, out.elements
  end

  # ---- data types the scan kernel does not answer in ---------------------

  def test_boolean_running_values_are_the_cores
    b = CA_BOOLEAN([true, false, true, true, true, false])
    it = b.group_by_category(@cat)
    assert_equal b.cumsum.data_type, it.cumsum.data_type
    assert_equal b.cummax.data_type, it.cummax.data_type
    assert_equal [1, 0, 2, UNDEF, 3, 0], it.cumsum.to_a
  end

  def test_complex_running_sum
    c = CArray.cmplx128(6) { |i| Complex(i, 1) }
    out = c.group_by_category(@cat).cumsum
    assert_equal CA_CMPLX128, out.data_type
    assert_equal [Complex(0, 1), Complex(1, 1), Complex(2, 2), UNDEF, Complex(6, 3), Complex(5, 1)],
                 out.to_a
  end
end

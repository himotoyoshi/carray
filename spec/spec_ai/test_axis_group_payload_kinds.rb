require "test/unit"
require "carray"

# axis_group reductions and running values answer as the core does over each
# group for every payload the core answers for -- boolean, complex, object, a
# Face -- not only the integer and float payloads the scatter kernels read.
class TestAxisGroupPayloadKinds < Test::Unit::TestCase

  def setup
    keys = CA_INT32([1, 2, 1, 2, 1, 3])
    keys[3] = UNDEF
    @cat = keys.categorize
  end

  def surface (a)
    a.to_a.flatten.map { |v| v.respond_to?(:unit) ? v.to_s : v }
  end

  def times
    CArray.time(%w[2024-01-03 2024-01-01 2024-01-02 2024-01-04 2024-01-01 2024-01-09], unit: :D)
  end

  def test_boolean_takes_the_cores_data_types
    b = CA_BOOLEAN([true, false, true, true, true, false])
    g = b[@cat]
    assert_equal b.sum(axis: 0, keep_axis: true).data_type, g.sum(axis: :group).data_type
    assert_equal [3, 0, 0], g.sum(axis: :group).to_a
    assert_equal b.cumsum.data_type, g.cumsum(axis: :group).data_type
    assert_equal b.cummax.data_type, g.cummax(axis: :group).data_type
    assert_equal [1, 0, 2, UNDEF, 3, 0], g.cumsum(axis: :group).to_a
  end

  def test_complex
    c = CArray.cmplx128(6) { |i| Complex(i, 1) }
    g = c[@cat]
    assert_equal [Complex(6, 3), Complex(1, 1), Complex(5, 1)], g.sum(axis: :group).to_a
    assert_equal [Complex(2, 1), Complex(1, 1), Complex(5, 1)], g.mean(axis: :group).to_a
    assert_equal [Complex(0, 1), Complex(1, 1), Complex(2, 2), UNDEF, Complex(6, 3), Complex(5, 1)],
                 g.cumsum(axis: :group).to_a
    assert_equal [1, 1, 2, UNDEF, 3, 1], g.cumcount(axis: :group).to_a
    assert_raise(CArray::DataTypeError) { g.min(axis: :group) }
  end

  def test_object_is_exact
    o = CArray.object(6) { |i| Rational(i, 3) }
    g = o[@cat]
    assert_equal [Rational(2), Rational(1, 3), Rational(5, 3)], g.sum(axis: :group).to_a
    assert_equal [Rational(2, 3), Rational(1, 3), Rational(5, 3)], g.mean(axis: :group).to_a
  end

  def test_time_answers_in_its_face
    g = times[@cat]
    assert_kind_of CATime, g.min(axis: :group)
    assert_equal %w[2024-01-01 2024-01-01 2024-01-09], surface(g.min(axis: :group))
    assert_equal %w[2024-01-02 2024-01-01 2024-01-09], surface(g.mean(axis: :group))
    assert_kind_of CATime, g.cummin(axis: :group)
    assert_equal ["2024-01-03", "2024-01-01", "2024-01-02", UNDEF, "2024-01-01", "2024-01-09"],
                 surface(g.cummin(axis: :group))
    assert_equal [1, 1, 2, UNDEF, 3, 1], g.cumcount(axis: :group).to_a
  end

  def test_time_refusals_are_the_cores
    g = times[@cat]
    core = assert_raise(TypeError) { times.sum }
    assert_equal core.message, assert_raise(TypeError) { g.sum(axis: :group) }.message
    core = assert_raise(TypeError) { times.cumsum }
    assert_equal core.message, assert_raise(TypeError) { g.cumsum(axis: :group) }.message
  end

  def test_timedelta
    g = CA_INT64([1, 2, 3, 4, 5, 6]).timedelta(unit: :D)[@cat]
    assert_kind_of CATimedelta, g.sum(axis: :group)
    assert_equal %w[9D 2D 6D], surface(g.sum(axis: :group))
    assert_equal ["1D", "2D", "4D", UNDEF, "9D", "6D"], surface(g.cumsum(axis: :group))
  end

  def test_band_preserving_grouping
    g   = CA_INT32([1, 2, 1]).categorize
    tm  = CArray.time((1..6).map { |i| "2024-01-%02d" % (7 - i) }, unit: :D).reshape(3, 2)
    grp = tm[g, nil]
    assert_equal %w[2024-01-02 2024-01-01 2024-01-04 2024-01-03], surface(grp.min(axis: :group))
    assert_equal %w[2024-01-04 2024-01-03 2024-01-04 2024-01-03], surface(grp.median(axis: :group))
    assert_equal %w[2024-01-06 2024-01-05 2024-01-04 2024-01-03 2024-01-02 2024-01-01],
                 surface(grp.cummin(axis: :group))
    assert_kind_of CATime, grp.map { |x| x.min }

    b = CA_BOOLEAN([[true, false], [true, true], [false, true]])[g, nil]
    assert_equal [[1, 1], [1, 1]], b.sum(axis: :group).to_a
    assert_equal [[1, 1], [7, 7]], b.sum(axis: :group, min_count: 2, fill_value: 7).to_a
  end

  def test_folding_a_band_needs_the_kernel
    g  = CA_INT32([1, 2, 1]).categorize
    tm = CArray.time((1..6).map { |i| "2024-01-%02d" % i }, unit: :D).reshape(3, 2)
    err = assert_raise(ArgumentError) { tm[g, nil].min(axis: [:group, 1]) }
    assert_match(/folding a band/, err.message)
    assert_equal [10.0, 5.0], CArray.float64(3, 2).seq[g, nil].sum(axis: [:group, 1]).to_a
  end
end

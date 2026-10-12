require "test/unit"
require "carray"

# locate_nearest_addr places each cell among the sorted reference values by
# counting, not by interpolating a position, so a NaN reference matches
# nothing, an infinite key keeps its place, and an integer key stays exact
# past 2**53.  join_asof is built on it.
class TestLocateNearestExact < Test::Unit::TestCase
  INF = Float::INFINITY
  NAN = Float::NAN

  def test_nan_reference_matches_nothing
    q = CA_DOUBLE([1.0, 3.0])
    r = CA_DOUBLE([0.5, 2.0, NAN])
    assert_equal [0, 1],     q.locate_nearest_addr(r, direction: :floor).to_a
    assert_equal [1, UNDEF], q.locate_nearest_addr(r, direction: :ceil).to_a
    assert_equal [0, 1],     q.locate_nearest_addr(r, direction: :round).to_a
  end

  def test_only_nan_references
    assert_equal [UNDEF, UNDEF],
                 CA_DOUBLE([1.0, 2.0]).locate_nearest_addr(CA_DOUBLE([NAN])).to_a
  end

  def test_infinite_keys_keep_their_place
    q = CA_DOUBLE([1.0, 3.0, INF, -INF, 0.0])
    r = CA_DOUBLE([-INF, 0.5, INF])
    assert_equal [2, 2, 2, 0, 1], q.locate_nearest_addr(r, direction: :ceil).to_a
    assert_equal [1, 1, 2, 0, 0], q.locate_nearest_addr(r, direction: :floor).to_a
    assert_equal [1, 1, 2, 0, 1], q.locate_nearest_addr(r, direction: :round).to_a
  end

  def test_integer_key_past_2_53
    q = CA_INT64([2**53 + 1])
    r = CA_INT64([2**53, 2**53 + 2])
    assert_equal [0], q.locate_nearest_addr(r, direction: :floor).to_a
    assert_equal [1], q.locate_nearest_addr(r, direction: :ceil).to_a
  end

  def test_nanosecond_time_key
    r = CArray.time(["2024-01-01T00:00:00.000000001",
                     "2024-01-01T00:00:00.000000003",
                     "2024-01-01T00:00:00.000000004"], unit: :ns)
    q = CArray.time(["2024-01-01T00:00:00.000000002"], unit: :ns)
    assert_equal [0], q.locate_nearest_addr(r, direction: :floor).to_a
    assert_equal [1], q.locate_nearest_addr(r, direction: :ceil).to_a
  end

  def test_round_takes_the_upper_neighbour_on_a_tie
    q = CA_DOUBLE([0.0, 1.0, 1.5, 1.6, 9.0, -9.0])
    assert_equal [0, 0, 1, 1, 1, 0],
                 q.locate_nearest_addr(CA_DOUBLE([1.0, 2.0])).to_a
  end

  def test_unsorted_reference_addresses_are_positions_in_it
    q = CA_DOUBLE([0.0, 1.0, 1.5, 9.0])
    assert_equal [1, 1, 0, UNDEF],
                 q.locate_nearest_addr(CA_DOUBLE([2.0, 1.0]), direction: :ceil).to_a
  end

  def test_query_shape_and_masks
    q = CA_DOUBLE([[1.0, 2.2], [NAN, 5.0]])
    assert_equal [[0, 1], [UNDEF, 2]],
                 q.locate_nearest_addr(CA_DOUBLE([1.0, 2.0, 3.0])).to_a
    m = CA_DOUBLE([1, 2, 3])
    m[1] = UNDEF
    assert_equal [0, UNDEF, 1], m.locate_nearest_addr(CA_DOUBLE([1, 3])).to_a
  end

  def test_empty_reference
    assert_equal [UNDEF], CA_DOUBLE([1.0]).locate_nearest_addr(CA_DOUBLE([])).to_a
  end

  def test_mixed_sign_integers_by_value
    assert_equal [UNDEF, 0],
                 CA_INT8([-1, 5]).locate_nearest_addr(CA_UINT8([0, 255]),
                                                      direction: :floor).to_a
  end

  def test_time_keys_of_different_units_either_way
    d = CArray.time(["2024-01-01", "2024-01-03"], unit: :D)
    h = CArray.time(["2024-01-01T00", "2024-01-02T01"], unit: :h)
    assert_equal [0, 1],     d.locate_nearest_addr(h, direction: :floor).to_a
    assert_equal [0, UNDEF], d.locate_nearest_addr(h, direction: :ceil).to_a
    assert_equal [0, 0],     h.locate_nearest_addr(d, direction: :floor).to_a
    assert_equal [0, 1],     h.locate_nearest_addr(d, direction: :ceil).to_a
  end

  def test_join_asof_with_nan_and_infinite_keys
    l = CAFrame.new("k" => CA_DOUBLE([1.0, 3.0]))
    r = CAFrame.new("k" => CA_DOUBLE([0.5, 2.0, NAN]), "w" => CA_INT64([10, 20, 99]))
    assert_equal [20, UNDEF], l.join_asof(r, on: "k", direction: :ceil)["w"].to_a
    l = CAFrame.new("k" => CA_DOUBLE([INF, -INF]))
    r = CAFrame.new("k" => CA_DOUBLE([-INF, 0.0, INF]), "w" => CA_INT64([10, 20, 30]))
    assert_equal [30, 10], l.join_asof(r, on: "k", direction: :floor)["w"].to_a
    assert_equal [30, 10], l.join_asof(r, on: "k", direction: :ceil)["w"].to_a
  end
end

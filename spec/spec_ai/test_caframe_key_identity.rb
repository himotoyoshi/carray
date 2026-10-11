require "test/unit"
require "carray"

# Whether two rows have the same key, as each CAFrame verb decides it.  The
# verbs reach the decision through different core primitives; these pin the
# places where they used to disagree.
class TestCAFrameKeyIdentity < Test::Unit::TestCase
  NAN = Float::NAN

  # A composite key compares each component as a single key does: NaN is one
  # value and -0.0 is 0.0.
  def test_composite_key_components_compare_as_single_keys
    f = CAFrame.new("a" => CA_DOUBLE([NAN, NAN, 0.0, -0.0, 1.0, 1.0]),
                    "b" => CA_INT64([1, 1, 2, 2, 3, 3]),
                    "v" => CA_INT64([1, 2, 3, 4, 5, 6]))
    g = f.group_by("a", "b").sum
    assert_equal 3, g.nrow
    assert_equal [3.0, 7.0, 11.0], g["v"].to_a
    assert_equal f.group_by("a").sum["v"].to_a, g["v"].to_a
  end

  def test_composite_key_labels_are_tuples_of_values
    f = CAFrame.new("a" => CA_INT64([1, 1, 2, 1]),
                    "b" => CA_OBJECT(["x", "y", "x", "x"]),
                    "v" => CA_INT64([1, 2, 3, 4]))
    g = f.group_by("a", "b").sum
    assert_equal [[1, "x"], [1, "y"], [2, "x"]], g.index.to_a
    assert_equal [5.0, 2.0, 3.0], g["v"].to_a
  end

  def test_composite_key_with_a_masked_component_has_no_group
    f = CAFrame.new("a" => CA_INT64([1, 1, 2, 1]),
                    "b" => CA_OBJECT(["x", "y", "x", "x"]),
                    "v" => CA_INT64([1, 2, 3, 4]))
    f["a"][2] = UNDEF
    g = f.group_by("a", "b").sum
    assert_equal [[1, "x"], [1, "y"]], g.index.to_a
    assert_equal [5.0, 2.0], g["v"].to_a
  end

  def test_composite_key_stack_rows
    f = CAFrame.new("a" => CA_DOUBLE([NAN, NAN, 1.0, 1.0]),
                    "b" => CA_INT64([1, 1, 2, 2]),
                    "v" => CA_INT64([1, 2, 3, 4]))
    assert_equal 2, f.stack_rows(by: ["a", "b"]).nrow
  end

  # A time key reads Time, Date and String values as instants, on either
  # side of the lookup and in a string column.
  def test_time_key_against_ruby_instants
    t = CArray.time(["2024-01-01", "2024-01-02"], unit: :D)
    assert_equal [UNDEF, 0], t.locate_addr([Time.utc(2024, 1, 2)]).to_a
    assert_equal [1, 0], t.locate_addr(CA_OBJECT([Time.utc(2024, 1, 2), "2024-01-01"])).to_a
    assert_equal [UNDEF, 0], t.locate_addr(CArray.string(["2024-01-02"])).to_a
    o = CA_OBJECT([Time.utc(2024, 1, 2), Time.utc(2025, 1, 1)])
    o[1] = UNDEF
    assert_equal [1, UNDEF], o.locate_addr(t).to_a
  end

  def test_join_time_key_with_an_object_time_column
    l = CAFrame.new("k" => CArray.time(["2024-01-01", "2024-01-02"], unit: :D),
                    "x" => CA_INT32([1, 2]))
    r = CAFrame.new("k" => CA_OBJECT([Time.utc(2024, 1, 2)]), "y" => CA_INT32([9]))
    assert_equal [UNDEF, 9], l.join(r, on: "k")["y"].to_a
    assert_equal [2], r.join(l, on: "k")["x"].to_a
  end

  def test_align_reads_an_array_as_values_of_the_key
    t = CAFrame.new("k" => CArray.time(["2024-01-01", "2024-01-02"], unit: :D),
                    "x" => CA_INT32([1, 2]))
    g = t.align("k", [Time.utc(2024, 1, 2), "2024-01-01", "2024-03-01"])
    assert_kind_of CATime, g["k"]
    assert_equal [2, 1, UNDEF], g["x"].to_a
    f = CAFrame.new("k" => CA_FLOAT64([1, 2.5, 3]), "x" => CA_INT32([0, 1, 2]))
    g = f.align("k", [1, 2.5])
    assert_equal :float64, g["k"].data_type
    assert_equal [0, 1], g["x"].to_a
    i = CAFrame.new("k" => CA_INT64([1, 2, 3]), "x" => CA_INT32([0, 1, 2]))
    assert_equal [2, UNDEF], i.align("k", [3, 1.5])["x"].to_a
  end

  # Two time keys of different units meet in the finer unit, so the answer
  # does not depend on which side is the receiver.
  def test_time_keys_of_different_units_either_way
    d = CArray.time(["2024-01-01", "2024-01-02", "2024-01-03"], unit: :D)
    h = CArray.time(["2024-01-01T00", "2024-01-02T00", "2024-01-02T01"], unit: :h)
    assert_equal [true, true, false], d.is_in(h).to_a
    assert_equal [true, true, false], h.is_in(d).to_a
    assert_equal [0, 1, UNDEF], d.locate_addr(h).to_a
    assert_equal [0, 1, UNDEF], h.locate_addr(d).to_a
    a = ->(k) { CAFrame.new("k" => k, "x" => CA_INT32([1, 2, 3])) }
    b = ->(k) { CAFrame.new("k" => k, "y" => CA_INT32([7, 8, 9])) }
    %i[left inner outer right].each do |how|
      assert_equal a.(d).join(b.(h), on: "k", how: how)["y"].to_a,
                   a.(h).join(b.(d), on: "k", how: how)["y"].to_a, how.to_s
    end
    assert_equal [7, 8, UNDEF, 9], a.(d).join(b.(h), on: "k", how: :outer)["y"].to_a
  end

  def test_month_and_day_keys
    d = CArray.time(["2024-01-01", "2024-01-02"], unit: :D)
    m = CArray.time(["2024-01"], unit: :M)
    assert_equal [true, false], d.is_in(m).to_a
    assert_equal [true], m.is_in(d).to_a
  end
end

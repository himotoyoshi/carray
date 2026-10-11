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

  # An object key orders as sort orders object cells: NaN last, and a pair
  # <=> cannot order raises the comparison error sort raises.
  def test_object_key_with_nan_or_nil_sorts_as_sort_does
    a = CA_OBJECT([2.0, NAN, 1.0])
    assert_equal [2, 0, 1], a.sort_addr.to_a
    assert_equal [2, 0, 1], CArray.sort_addr(a).to_a
    assert_equal [1.0, 2.0], CAFrame.new("a" => a).sort_by_key("a")["a"].to_a[0, 2]
    n = CA_OBJECT([2, nil, 1])
    e = assert_raise(ArgumentError) { CAFrame.new("a" => n).sort_by_key("a") }
    assert_match(/comparison of Integer with nil failed/, e.message)
  end

  # Fixed-width strings of different widths are the same strings; a join
  # meets them at the wider width, from either side.  Raw fixlen cells of
  # different widths are values of different lengths and are refused,
  # naming the widths.
  def test_fixed_width_string_keys_of_different_widths
    a = CArray.fixlen_string(%w[a b c])
    b = CArray.fixlen_string(%w[aa b cc])
    assert_equal [UNDEF, 1, UNDEF], a.locate_addr(b).to_a
    assert_equal [UNDEF, 1, UNDEF], b.locate_addr(a).to_a
    l = CAFrame.new("k" => a, "x" => CA_INT32([1, 2, 3]))
    r = CAFrame.new("k" => b, "y" => CA_INT32([7, 8, 9]))
    assert_equal [UNDEF, 8, UNDEF], l.join(r, on: "k")["y"].to_a
    assert_equal [UNDEF, 2, UNDEF], r.join(l, on: "k")["x"].to_a
    assert_equal [UNDEF, 8, UNDEF, 7, 9], l.join(r, on: "k", how: :outer)["y"].to_a
    e = assert_raise(CArray::DataTypeError) { a.parent.locate_addr(b.parent) }
    assert_match(/1 bytes wide like self, not 2/, e.message)
  end

  # join matches rows as SQL joins do: one row per matching pair, a masked
  # key matching nothing.
  def rows_of(j)
    j.nrow.times.map { |i| j.column_names.map { |c| j[c][i] } }
  end

  def test_join_is_many_to_many
    obs  = CAFrame.new("station" => CA_OBJECT(%w[A B A C]), "temp" => CA_INT64([10, 20, 30, 40]))
    meta = CAFrame.new("station" => CA_OBJECT(%w[A A B D]), "sensor" => CA_OBJECT(%w[a1 a2 b1 d1]))
    pairs = [["A", 10, "a1"], ["A", 10, "a2"], ["B", 20, "b1"], ["A", 30, "a1"], ["A", 30, "a2"]]
    assert_equal pairs, rows_of(obs.join(meta, on: "station", how: :inner))
    assert_equal pairs + [["C", 40, UNDEF]], rows_of(obs.join(meta, on: "station"))
    assert_equal pairs + [["C", 40, UNDEF], ["D", UNDEF, "d1"]],
                 rows_of(obs.join(meta, on: "station", how: :outer))
    assert_equal [["A", 10, "a1"], ["A", 30, "a1"], ["A", 10, "a2"], ["A", 30, "a2"],
                  ["B", 20, "b1"], ["D", UNDEF, "d1"]],
                 rows_of(obs.join(meta, on: "station", how: :right))
  end

  def test_join_masked_keys_match_nothing_and_stay_unmatched
    l = CAFrame.new("k" => CA_INT64([1, 0, 2]), "x" => CA_INT64([1, 2, 3]))
    l["k"][1] = UNDEF
    r = CAFrame.new("k" => CA_INT64([2, 0]), "y" => CA_INT64([7, 8]))
    r["k"][1] = UNDEF
    assert_equal [[1, 1, UNDEF], [UNDEF, 2, UNDEF], [2, 3, 7]], rows_of(l.join(r, on: "k"))
    assert_equal [[2, 3, 7]], rows_of(l.join(r, on: "k", how: :inner))
    assert_equal [[2, 3, 7], [UNDEF, UNDEF, 8]], rows_of(l.join(r, on: "k", how: :right))
    assert_equal 4, l.join(r, on: "k", how: :outer).nrow
  end

  def test_left_join_shares_the_left_columns
    l = CAFrame.new("k" => CA_INT64([1, 2]), "x" => CA_INT64([5, 6]))
    r = CAFrame.new("k" => CA_INT64([2, 3]), "y" => CA_INT64([7, 8]))
    assert_same l["x"], l.join(r, on: "k")["x"]
    r2 = CAFrame.new("k" => CA_INT64([1, 1]), "y" => CA_INT64([7, 8]))
    j = l.join(r2, on: "k")
    assert_equal [5, 5, 6], j["x"].to_a
    j["x"][1] = 99
    assert_equal [99, 6], l["x"].to_a
  end

  # at finds a NaN label, as join and group_by match NaN keys.
  def test_at_finds_a_nan_label
    s = CAFrame.new("k" => CA_DOUBLE([NAN, 1.0]), "v" => CA_INT64([1, 2])).set_index("k")
    assert_equal 1, s.at(NAN)["v"]
    o = CAFrame.new("k" => CA_OBJECT([NAN, 1]), "v" => CA_INT64([1, 2])).set_index("k")
    assert_equal 1, o.at(0.0 / 0.0)["v"]
    g = CAFrame.new("a" => CA_DOUBLE([NAN, NAN, 1.0]), "v" => CA_INT64([1, 2, 3])).group_by("a").sum
    assert_equal 3.0, g.at(NAN)["v"]
    d = CAFrame.new("k" => CA_DOUBLE([NAN, NAN]), "v" => CA_INT64([1, 2])).set_index("k")
    e = assert_raise(ArgumentError) { d.at(NAN) }
    assert_match(/f\.index\.is_nan/, e.message)
  end

  # A numeric index is looked up with a number.
  def test_at_on_a_numeric_index_takes_a_number
    f = ->(k) { CAFrame.new("k" => k, "v" => CA_INT64([10, 20])).set_index("k") }
    assert_equal 20, f.(CA_FLOAT64([1, 2.5])).at(2.5)["v"]
    assert_equal 20, f.(CA_INT64([1, 2])).at(2.0)["v"]
    ["2", true].each do |label|
      e = assert_raise(ArgumentError) { f.(CA_INT64([1, 2])).at(label) }
      assert_match(/the label must be a number/, e.message)
    end
    assert_raise(ArgumentError) { f.(CA_FLOAT64([1, 2.5])).at("2.5") }
    assert_equal 20, f.(CA_BOOLEAN([true, false])).at(false)["v"]
  end
end

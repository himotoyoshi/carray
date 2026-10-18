# A time Face reads an operand the same way at every door that compares
# with it: the operators, count(v), mask_eq, the searches, linear_section,
# is_in and the set operations, pmax / pmin.  The reference and the operand
# meet in the reference's unit when the operand sits on its grid and in the
# finer unit the two share otherwise; an assignment, which has to land on
# the grid, still refuses an operand off it.  UNDEF is undefined in every
# space and answers as it does for a plain array; a masked cell of a query
# finds nothing.

require "test/unit"
require "carray"

class TestTimeOperandDoors < Test::Unit::TestCase

  def days
    CArray.time(%w[2024-01-01 2024-01-02 2024-01-03 2024-01-04 2024-01-05], unit: :D)
  end

  def spans
    d = days
    d - d[0]
  end

  def hours (*texts)
    CArray.time(texts, unit: :h)
  end

  # Operands that name the third cell, and the cell they name (nil = none).
  TIME_OPERANDS = {
    "element"         => [-> (t) { t[2] }, 2],
    "Time"            => [-> (_) { Time.utc(2024, 1, 3) }, 2],
    "Date"            => [-> (_) { require "date"; Date.new(2024, 1, 3) }, 2],
    "text"            => [-> (_) { "2024-01-03" }, 2],
    "finer element"   => [-> (_) { CArray.time(["2024-01-03T00:00:00"], unit: :s)[0] }, 2],
    "off-grid text"   => [-> (_) { "2024-01-03T05:00" }, nil],
    "off-grid Time"   => [-> (_) { Time.utc(2024, 1, 3, 5) }, nil],
    "off-grid element"=> [-> (_) { CArray.time(["2024-01-03T05:00"], unit: :h)[0] }, nil],
  }

  SPAN_OPERANDS = {
    "element"          => [-> (d) { d[2] }, 2],
    "finer element"    => [-> (_) { t = CArray.time(%w[2024-01-01T00 2024-01-03T00], unit: :h); (t - t[0])[1] }, 2],
    "off-grid element" => [-> (_) { t = CArray.time(%w[2024-01-01T00 2024-01-03T05], unit: :h); (t - t[0])[1] }, nil],
  }

  # Each door asked which cell equals the operand.
  DOORS = {
    "eq"             => ->(r, v) { r.eq(v).to_a.index(true) },
    "count"          => ->(r, v) { r.count(v) == 1 ? r.eq(v).to_a.index(true) : nil },
    "mask_eq"        => ->(r, v) { r.mask_eq(v).is_masked.to_a.index(true) },
    "[:eq, v] ="     => ->(r, v) { x = r.copy; x[:eq, v] = UNDEF; x.is_masked.to_a.index(true) },
    "is_in"          => ->(r, v) { r.is_in(v).to_a.index(true) },
    "is_in([v])"     => ->(r, v) { r.is_in([v]).to_a.index(true) },
    "intersection"   => ->(r, v) { (s = r.intersection([v])).elements == 0 ? nil : r.eq(s[0]).to_a.index(true) },
    "search"         => ->(r, v) { r.search(v) },
    "bsearch"        => ->(r, v) { r.bsearch(v) },
    "locate_addr"    => ->(r, v) { r.locate_addr([v]).to_a.index { |x| !UNDEF.equal?(x) } },
    "linear_section" => ->(r, v) { (x = r.linear_section(v)) == x.round ? x.round : nil },
  }

  def check (reference, operands)
    operands.each do |name, (make, cell)|
      DOORS.each do |door, ask|
        assert_equal(cell, ask.(reference, make.(reference)), "#{door} with #{name}")
      end
    end
  end

  def test_a_time_reads_an_operand_the_same_way_at_every_door
    check(days, TIME_OPERANDS)
  end

  def test_a_duration_reads_an_operand_the_same_way_at_every_door
    check(spans, SPAN_OPERANDS)
  end

  def test_an_off_grid_operand_is_ordered_as_the_instant_it_is
    d = days
    assert_equal [true, true, true, false, false], (d < "2024-01-03T05:00").to_a
    assert_equal 2, d.search_nearest("2024-01-03T05:00")
    assert_in_delta 2 + 5.0 / 24, d.linear_section("2024-01-03T05:00"), 1e-12
    assert_equal [false] * 5, d.eq(hours("2024-01-03T05")[0]).to_a
  end

  def test_the_reference_is_not_converted_when_the_operand_is_on_its_grid
    d = days
    ref, op = d.comparable_pair("2024-01-03")
    assert_same d, ref
    assert_equal :D, op.unit.base
    ref, op = d.comparable_pair("2024-01-03T05:00")
    assert_equal :s, ref.unit.base
    assert_equal :s, op.unit.base
  end

  def test_an_assignment_still_lands_on_the_grid
    assert_raise(ArgumentError) { days.copy[0] = "2024-01-03T05:00" }
    assert_raise(ArgumentError) { days.copy[0..0] = hours("2024-01-03T05") }
  end

  def test_a_duration_reads_values_one_by_one_as_a_time_does
    s = spans
    assert_equal [false, false, true, false, false], s.is_in([s[2]]).to_a
    assert_equal [false, false, true, false, false], s.is_in(s[2]).to_a
    assert_equal [false, false, true, false, false], s.is_in(CA_OBJECT([s[2]])).to_a
    assert_equal [UNDEF, UNDEF, 0, UNDEF, UNDEF], s.locate_addr([s[2]]).to_a
    assert_equal ["2D", "UNDEF"], s.to_comparable([s[2], UNDEF]).to_a.map(&:to_s)
    assert_equal ["2D"], s.to_comparable(CA_OBJECT([s[2]])).to_a.map(&:to_s)
    d = days
    assert_equal ["2024-01-03", "UNDEF"], d.to_comparable(["2024-01-03", UNDEF]).to_a.map(&:to_s)
  end

  def test_undef_answers_as_for_a_plain_array
    [days, spans, CA_INT64([0, 1, 2, 3, 4])].each do |r|
      assert_nil r.search(UNDEF), r.class.name
      assert_nil r.bsearch(UNDEF), r.class.name
      assert_nil r.search_nearest(UNDEF), r.class.name
      assert_equal [false] * 5, r.is_in([UNDEF]).to_a, r.class.name
      assert_equal 0, r.count(UNDEF), r.class.name
    end
  end

  def test_a_masked_query_cell_finds_nothing
    a = CA_INT64([0, 1, 2])
    q = CA_INT64([2, 0, 1])
    q[1] = UNDEF
    %i[search bsearch search_nearest search_addr bsearch_addr search_nearest_addr].each do |m|
      assert_equal [2, UNDEF, 1], a.public_send(m, q).to_a, m.to_s
    end
    d = days
    tq = CArray.time(%w[2024-01-02 2024-01-04], unit: :D)
    tq[0] = UNDEF
    assert_equal [UNDEF, 3], d.search(tq).to_a
  end

  def test_pmax_and_pmin_of_a_time_order_by_instant
    d = days
    assert_equal %w[2024-01-03 2024-01-03 2024-01-03 2024-01-04 2024-01-05],
                 d.pmax(Time.utc(2024, 1, 3)).to_a.map(&:to_s)
    assert_equal %w[2024-01-01 2024-01-02 2024-01-03 2024-01-03 2024-01-03],
                 d.pmin("2024-01-03").to_a.map(&:to_s)
    r = d.pmax(d.reverse)
    assert_kind_of CATime, r
    assert_equal %w[2024-01-05 2024-01-04 2024-01-03 2024-01-04 2024-01-05], r.to_a.map(&:to_s)
    r = d.pmax("2024-01-03T05:00")
    assert_equal :s, r.unit.base
    assert_equal "2024-01-03T05:00:00Z", r[0].to_s
    assert_equal [UNDEF] * 5, d.pmax(UNDEF).to_a
    m = d.copy
    m[0] = UNDEF
    assert_equal UNDEF, m.pmax("2024-01-03")[0]
    assert_equal d.pmax("2024-01-03").to_a, d.maximum("2024-01-03").to_a
    assert_equal d.pmin("2024-01-03").to_a, d.minimum("2024-01-03").to_a
    assert_raise(TypeError) { d.pmax(3) }
  end

end

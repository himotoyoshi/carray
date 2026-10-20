# ----------------------------------------------------------------------------
#
#  spec_ai/test_sort_addr_multi_key_order.rb
#
#  CArray.sort_addr(*keys, masked_position:) against the order it promises,
#  written out in Ruby:
#
#    - the keys decide in turn, the first one first;
#    - a masked cell sorts after every value (masked_position: :last) or
#      before every value (:first), and two masked cells tie;
#    - NaN sorts after every number, and two NaN tie;
#    - -0.0 and 0.0 tie;
#    - rows that tie on every key stay in row order.
#
#  Keys of the numeric data types are sorted by refinement (MSD: the first
#  key whole, then each run of rows that tie on it by the next key); keys of
#  any other type by one comparator over every key.  Both are checked, over
#  the crossings of data type, mask, NaN, view and masked_position.
#
# ----------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestSortAddrMultiKeyOrder < Test::Unit::TestCase

  NUMERIC_TYPES = [:boolean, :int8, :uint8, :int16, :uint16, :int32, :uint32,
                   :int64, :uint64, :float32, :float64]

  # The order a key's cell takes: [class, value], class 0 for a number,
  # 1 for NaN, and the masked cells at the masked_position end.
  def cell_rank (key, row, masked_last)
    v = key[row]
    return [masked_last ? 2 : -1, 0] if v.equal?(UNDEF)
    v = ( v ? 1 : 0 ) if v == true or v == false
    return [1, 0] if v.is_a?(Float) and v.nan?
    return [0, v]
  end

  def expected_order (keys, masked_last)
    rows = (0...keys.first.elements).to_a
    return rows.sort_by { |row| keys.map { |key| cell_rank(key, row, masked_last) } + [row] }
  end

  def make_key (type, n, rng)
    case type
    when :boolean
      key = CArray.boolean(n) { rng.rand(2) == 1 }
    when :float32, :float64
      cells = [-1.5, -0.0, 0.0, 2.25, Float::NAN]
      key = CArray.new(type, [n]) { cells[rng.rand(cells.size)] }
    when :uint8, :uint16, :uint32, :uint64
      top = 2**(CArray.new(type, [1]).bytes * 8) - 1
      key = CArray.new(type, [n]) { [0, 1, top][rng.rand(3)] }
    when :object
      key = CA_OBJECT(Array.new(n) { ["a", "b", "c"][rng.rand(3)] })
    else
      key = CArray.new(type, [n]) { [-3, 0, 2][rng.rand(3)] }
    end
    key[CArray.boolean(n) { rng.rand < 0.25 }] = UNDEF if rng.rand(2) == 1
    key = key[CArray.int64(n).seq.reverse] if rng.rand(3) == 0
    return key
  end

  def check_random (types, cases, seed)
    rng = Random.new(seed)
    cases.times do
      n    = [0, 1, 2, rng.rand(3..30), rng.rand(30..200)][rng.rand(5)]
      keys = Array.new(rng.rand(1..4)) { make_key(types[rng.rand(types.size)], n, rng) }
      [:last, :first].each do |masked_position|
        got = CArray.sort_addr(*keys, masked_position: masked_position).to_a
        assert_equal expected_order(keys, masked_position == :last), got,
                     "keys #{keys.map(&:data_type_name)} masked_position: #{masked_position}"
      end
    end
  end

  def test_numeric_keys_sorted_by_refinement
    check_random(NUMERIC_TYPES, 400, 1)
  end

  def test_keys_with_an_object_key_sorted_by_the_comparator
    check_random(NUMERIC_TYPES + [:object], 200, 2)
  end

  # Masked cells and NaN of the first key are runs of their own, which the
  # second key orders.
  def test_masked_and_nan_runs_are_ordered_by_the_next_key
    a = CA_FLOAT64([Float::NAN, 1.0, UNDEF, Float::NAN, UNDEF, 1.0])
    b = CA_INT32([   3,          2,   1,     0,          5,     1])
    assert_equal [5, 1, 3, 0, 2, 4], CArray.sort_addr(a, b).to_a
    assert_equal [2, 4, 5, 1, 3, 0], CArray.sort_addr(a, b, masked_position: :first).to_a
  end

  def test_negative_zero_ties_with_zero
    a = CA_FLOAT64([0.0, -0.0, 0.0, -0.0])
    b = CA_INT32([3, 2, 1, 0])
    assert_equal [3, 2, 1, 0], CArray.sort_addr(a, b).to_a
  end

  # The rows of a key of more than one axis are its cells in row-major order,
  # and the answer has the shape of the first key.
  def test_keys_of_two_axes
    a = CA_INT32([[1, 0], [1, 0]])
    b = CA_FLOAT64([[0.5, 0.25], [0.125, 0.75]])
    assert_equal [[1, 3], [2, 0]], CArray.sort_addr(a, b).to_a
  end

end

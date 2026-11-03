# frozen_string_literal: true
#
# The three String Faces holding the same Strings answer the same.

require "test/unit"
require "carray"

class TestStringFacesAnswerAlike < Test::Unit::TestCase
  VALUES = %w[ab b ab 1].freeze

  def faces
    {
      "string" => CArray.string(VALUES),
      "fixlen" => CArray.fixlen_string(VALUES, bytes: 2),
      "const"  => CArray.const_string(VALUES),
    }
  end

  def answers (&block)
    faces.transform_values { |a|
      r = begin
            block.call(a)
          rescue StandardError => e
            e.class
          end
      r.is_a?(CArray) ? r.to_a : r
    }
  end

  def assert_alike (expected, &block)
    answers(&block).each { |name, got| assert_equal(expected, got, name) }
  end

  def test_string_predicates_read_their_argument
    assert_alike([true, false, true, false]) { |a| a.start_with?(/a/) }
    assert_alike([true, true, true, false]) { |a| a.start_with?("b", "a") }
    assert_alike(TypeError) { |a| a.end_with?(1) }
    assert_alike(TypeError) { |a| a.include?(/a/) }
    assert_alike(TypeError) { |a| a.include?(1) }
    assert_alike([true, true, true, false]) { |a| a.include?("b") }
  end

  def test_a_value_that_is_no_string_is_in_no_cell
    assert_alike([false, false, false, false]) { |a| a.eq(1) }
    assert_alike([true, true, true, true]) { |a| a.ne(1) }
    assert_alike(0) { |a| a.count(1) }
    assert_alike(nil) { |a| a.search(1) }
    assert_alike([false, false, false, false]) { |a| a.is_in(1) }
    assert_alike(VALUES) { |a| a.mask_eq(1) }
  end

  def test_undef_asks_the_mask
    assert_alike(0) { |a| a.count(UNDEF) }
    assert_alike([false, false, false, false]) { |a| a.eq(UNDEF) }
    c = CArray.const_string(["a", nil])
    assert_equal(1, c.count(UNDEF))
  end

  def test_match_and_the_searches
    assert_alike([true, false, true, false]) { |a| a.match(/a/) }
    assert_alike(1) { |a| a.search_addr("b") }
    assert_alike(1) { |a| a.sort.bsearch("ab") }
    assert_alike(1) { |a| a.sort.bsearch_addr("ab") }
    assert_alike(ArgumentError) { |a| a.search(axis: 0) }
    assert_nil(CArray.const_string(VALUES).find_value_index(1))
    assert_equal(1, CArray.const_string(VALUES).find_value_index("b"))
  end

  def test_picks_by_order
    assert_alike(%w[ab b ab aa]) { |a| a.pmax("aa") }
    assert_alike(%w[aa aa aa 1]) { |a| a.pmin("aa") }
    assert_alike(%w[ab b ab aa]) { |a| a.maximum("aa") }
    assert_kind_of(CAConstString, CArray.const_string(VALUES).pmax("aa"))
    assert_equal(%w[ab b ab 1], CArray.const_string(VALUES).fmax(CArray.const_string(VALUES)).to_a)
  end

  def test_addresses_of_the_extremes
    assert_alike(3) { |a| a.min_addr }
    assert_alike(1) { |a| a.max_addr }
    assert_alike([0, 1]) { |a| a.reshape(2, 2).max_addr(axis: 0) }
  end

  def test_clip_keeps_what_it_writes
    assert_alike(%w[zzz zzz zzz zzz]) { |a| a.clip("zzz", "zzzz") }
    d = CArray.time(%w[2024-01-01 2024-01-02], unit: :D)
    h = CArray.time(%w[2024-01-01T06 2024-01-02T12], unit: :h)
    assert_equal(%w[2024-01-01T06:00:00Z 2024-01-02T00:00:00Z], d.clip(h[0], h[1]).to_a.map(&:to_s))
  end

  def test_factorize_gives_levels_of_the_kind
    faces.each { |name, a|
      codes, levels = a.factorize
      assert_equal(a.class, levels.class, name)
      assert_equal(%w[ab b 1], levels.to_a, name)
      assert_equal([0, 1, 0, 2], codes.to_a, name)
    }
  end

  def test_count_of_a_const_string_keeps_the_native_answer
    assert_equal(2, CArray.const_string(VALUES).count("ab"))
    assert_equal(0, CArray.const_string(VALUES).search("ab"))
  end

  def test_a_fixed_string_picks_against_any_array_of_strings
    v = %w[ab b ab 1 zz b]
    w = %w[c a abc 0 zz bb]
    f = CArray.fixlen_string(v, bytes: 2)
    [CArray.string(w), CArray.const_string(w), CA_OBJECT(w)].each do |x|
      assert_equal v.zip(w).map(&:max), f.pmax(x).to_a, x.class.name
      assert_equal v.zip(w).map(&:min), f.pmin(x).to_a, x.class.name
      assert_instance_of CAFixlenString, f.pmax(x)
      assert_equal 3, f.pmax(x).bytes
    end
  end
end

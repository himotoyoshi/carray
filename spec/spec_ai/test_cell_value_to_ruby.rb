# ----------------------------------------------------------------------------
#
#  spec_ai/test_cell_value_to_ruby.rb
#
#  A cell handed to Ruby -- to a convert block, to a CAObject's hooks, as a
#  window's fill value -- is the value ca[i] gives: true or false for a
#  boolean, the element for a Face.
#
# ----------------------------------------------------------------------------

$LOAD_PATH.unshift File.expand_path("../../../ext", __FILE__)
$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "carray"
require "test/unit"

class TestCellValueToRuby < Test::Unit::TestCase

  def test_convert_yields_true_and_false_for_a_boolean
    b = CA_BOOLEAN([1, 0])
    got = []
    b.convert(CA_INT32) { |v| got << v; 0 }
    assert_equal [true, false], got
  end

  def test_convert_yields_the_element_of_a_face
    t = CArray.time(["2024-01-02", "2024-03-04"], unit: :D)
    got = []
    t.convert(CA_INT64) { |v| got << v; 0 }
    assert_equal [t[0], t[1]], got
    s = CArray.const_string(%w[ab c]).to_string
    got = []
    s.convert(CA_INT32) { |v| got << v; 0 }
    assert_equal ["ab", "c"], got
  end

  class BooleanHooks < CAObject
    attr_reader :got
    def initialize
      super(:boolean, [3])
      @got = []
    end
    private
    def fetch_addr (a); a.odd?; end
    def store_addr (a, v); @got << [:addr, v]; end
    def copy_data (d); d[] = CA_BOOLEAN([0, 1, 0]); end
    def sync_data (d); end
    def fill_data (v); @got << [:fill, v]; end
  end

  def test_a_boolean_caobject_hook_receives_true_and_false
    o = BooleanHooks.new
    o[1] = true
    o[0] = false
    o.fill(true)
    assert_equal [[:addr, true], [:addr, false], [:fill, true]], o.got
  end

  def test_a_boolean_window_fill_value_is_true_or_false
    b = CA_BOOLEAN([1, 0, 1])
    assert_equal true, b.window(-1..1, fill_value: true).fill_value
  end

end

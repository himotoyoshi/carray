require "test/unit"
require "carray"

# A fill_value the result cannot hold is refused whether or not a cell
# needed it.  sum and mean took "x" silently when every cell was defined.
class TestFillValueAlwaysChecked < Test::Unit::TestCase

  def test_refused_without_undefined_cells
    a = CA_FLOAT64([1, 2])
    %i[sum mean min max median].each do |m|
      assert_raise(ArgumentError, m.to_s) { a.send(m, fill_value: "x") }
    end
    assert_raise(ArgumentError) { a.reshape(1, 2).sum(axis: 1, fill_value: "x") }
  end

  def test_a_usable_fill_changes_nothing_when_unused
    a = CA_FLOAT64([1, 2])
    assert_equal 3.0, a.sum(fill_value: 0)
    assert_equal [3.0], a.reshape(1, 2).sum(axis: 1, fill_value: -1).to_a
  end

end

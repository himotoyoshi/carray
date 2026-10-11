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
end

require "test/unit"
require "carray"

# CAFrame#verify: named rules judged per row, the verdicts returned as a
# frame of boolean columns (true = the rule holds).
class TestFrameVerify < Test::Unit::TestCase
  def frame
    age = CA_INT32([30, -1, 20, 41])
    age[2] = UNDEF
    CAFrame.new({ "age"   => age,
                  "start" => CA_INT32([1, 5, 2, 3]),
                  "end"   => CA_INT32([4, 6, 1, 3]),
                  "p"     => CA_FLOAT64([[1, 2], [-1, 0], [3, -4], [5, 6]]) },
                index: CA_OBJECT(%w[a b c d]), axis_name: "id")
  end

  RULES = {
    "age is not negative" => ->(f) { f["age"] >= 0 },
    "end after start"     => ->(f) { f["end"] > f["start"] },
  }.freeze

  def test_one_column_per_rule_matching_the_rule
    df = frame
    r = df.verify(RULES)
    assert_equal RULES.keys, r.column_names
    RULES.each { |name, rule| assert_equal rule.(df).to_a, r[name].to_a, name }
    assert_equal [true, true, false, false], r["end after start"].to_a
  end

  def test_index_and_row_axis_name_are_kept
    r = frame.verify(RULES)
    assert_equal %w[a b c d], r.index.to_a
    assert_equal "id", r.axis_name
  end

  # A rule that read a masked value cannot judge the row: UNDEF, not false.
  def test_a_masked_input_leaves_the_verdict_undef
    v = frame.verify(RULES)["age is not negative"]
    assert_equal [true, false, UNDEF, true], v.to_a
    assert_equal 1, v.count(false)
    assert_equal 1, v.count_masked
  end

  # A rule over an N-D column answers per cell, and the failing cells can be
  # masked in place.
  def test_an_nd_rule_keeps_its_shape
    df = frame
    v = df.verify("p is not negative" => ->(f) { f["p"] >= 0 })["p is not negative"]
    assert_equal [4, 2], v.shape
    df["p"][v.not] = UNDEF
    assert_equal [[1.0, 2.0], [UNDEF, 0.0], [3.0, UNDEF], [5.0, 6.0]], df["p"].to_a
    assert_equal [true, false, false, true], v.all(axis: 1).to_a
  end

  def test_the_verdicts_select_rows
    df = frame
    r = df.verify(RULES)
    assert_equal %w[c d], df.filter { |f| r["end after start"].not }.index.to_a
  end

  def start_positive(f)
    f["start"] > 0
  end

  def test_a_method_is_a_rule
    r = frame.verify("start positive" => method(:start_positive))
    assert_equal [true] * 4, r["start positive"].to_a
  end

  def test_refusals
    df = frame
    assert_raise(ArgumentError) { df.verify({}) }
    assert_raise(ArgumentError) { df.verify([["x", ->(f) { f["age"] > 0 }]]) }
    assert_raise(ArgumentError) { df.verify("" => ->(f) { f["age"] > 0 }) }
    assert_raise(TypeError) { df.verify(x: ->(f) { f["age"] > 0 }) }
    assert_raise(ArgumentError) { df.verify("x" => 1) }
    err = assert_raise(ArgumentError) { df.verify("not boolean" => ->(f) { f["age"] }) }
    assert_match(/"not boolean".*int32/, err.message)
    err = assert_raise(ArgumentError) { df.verify("short" => ->(f) { f["age"][0..1] > 0 }) }
    assert_match(/verify: rule "short" .*expected 4 rows/, err.message)
    err = assert_raise(ArgumentError) { df.verify("scalar verdict" => ->(f) { CScalar.boolean { true } }) }
    assert_match(/verify: rule "scalar verdict" .*expected 4 rows/, err.message)
    assert_raise(ArgumentError) { df.verify("scalar" => ->(f) { CA_BOOLEAN([true])[0] }) }
  end

  def test_an_error_in_a_rule_passes_through
    assert_raise(KeyError) { frame.verify("missing" => ->(f) { f["nope"] > 0 }) }
  end
end

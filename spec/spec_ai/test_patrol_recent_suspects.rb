require "test/unit"
require "carray"

# The answers settled for the suspects of the recent-fix patrol.
class TestPatrolRecentSuspects < Test::Unit::TestCase
  def frame
    t = CArray.time(["2024-01-01", "2024-01-02", "2024-01-03"], unit: :D)
    CAFrame.new("t" => t, "v" => CA_FLOAT64([1, 2, 3]), "g" => CA_INT32([0, 0, 1]))
  end

  # resample takes a CArray key as group_by does, labelled by its place.
  def test_resample_by_takes_a_carray_key
    by_col = frame.resample("t", "2 days", by: "g").sum
    by_arr = frame.resample("t", "2 days", by: CA_INT32([0, 0, 1])).sum
    assert_equal by_col["v"].to_a, by_arr["v"].to_a
    assert_equal by_col["g"].to_a, by_arr["key0"].to_a
    assert_equal ["g", "key1", "t", "v"],
                 frame.resample("t", "2 days", by: ["g", CA_INT32([5, 5, 6])]).sum.column_names
    e = assert_raise(ArgumentError) { frame.resample("t", "2 days", by: CA_INT32([0, 1])) }
    assert_match(/resample: the key has 2 values for 3 rows/, e.message)
  end

  # A windowed reduction that takes no keyword says so as a frame does.
  def test_windowed_value_reductions_refuse_keywords
    w = CAFrame.new("t" => CA_INT32([1, 2, 3]), "v" => CA_FLOAT64([1, 2, 3])).windows(on: "t", before: 1)
    [-> { w.count(fill_value: 0) }, -> { w.first("v", min_count: 1) }, -> { w.quantile(fill_value: 0) }].each do |op|
      e = assert_raise(ArgumentError) { op.call }
      assert_match(/\Aunknown keyword: :(fill_value|min_count)\z/, e.message)
    end
  end

  # A Face state mismatch is reported by the verb that was called.
  def test_a_face_state_mismatch_names_the_verb
    a = CArray.time(["2024-01-01"], unit: :D)
    b = CArray.time(["2024-01-01"], unit: :h)
    { "stack" => -> { CArray.stack([a, b]) }, "meld" => -> { CArray.meld(a, b) },
      "concatenate" => -> { CArray.concatenate([a, b]) } }.each do |verb, op|
      e = assert_raise(ArgumentError) { op.call }
      assert e.message.start_with?("#{verb}: Face state mismatch"), e.message
    end
  end

  # The String Faces refuse an ordering with a value that is not a String
  # alike, and have no nearest string.
  def test_string_faces_answer_an_ordering_alike
    faces = [CArray.string(%w[a b]).to_fixlen_string, CArray.string(%w[a b]),
             CArray.const_string(%w[a b])]
    faces.each do |x|
      e = assert_raise(ArgumentError) { x.pmax(1) }
      assert_equal "pmax: comparison of String with Integer failed", e.message
      e = assert_raise(ArgumentError) { x.maximum(:s) }
      assert_equal "maximum: comparison of String with :s failed", e.message
      e = assert_raise(ArgumentError) { x.clip(1, 2) }
      assert_equal "clip: comparison of String with Integer failed", e.message
      assert_raise(CArray::DataTypeError) { x.search_nearest("b") }
      assert_equal %w[aa b], x.pmax("aa").to_a
      assert_equal %w[a a], x.clip(nil, "a").to_a
    end
  end
end

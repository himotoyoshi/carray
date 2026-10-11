require "test/unit"
require "carray"

# What a refusal says when values cannot be put in order or compared: the
# values, the column or key involved, and the conversion that would work.
class TestRefusalMessagesOrder < Test::Unit::TestCase

  def test_categorize_sort_labels_puts_nan_last
    assert_equal [0.5, 1.0], CA_DOUBLE([0.0 / 0.0, 1.0, 0.5]).categorize(sort_labels: true).labels[0, 2]
    assert CA_DOUBLE([0.0 / 0.0, 1.0]).categorize(sort_labels: true).labels.last.nan?
  end

  def test_categorize_sort_labels_names_labels_it_cannot_order
    e = assert_raise(ArgumentError) { CA_OBJECT([1, "a"]).categorize(sort_labels: true) }
    assert_match(/cannot order the labels 1 and "a"/, e.message)
  end

  def test_pivot_names_a_key_it_cannot_sort
    f = CAFrame.new("r" => CA_OBJECT([1, nil]), "c" => CA_INT64([1, 1]), "v" => CA_INT64([1, 2]))
    e = assert_raise(ArgumentError) { f.pivot(index: "r", columns: "c", values: "v") }
    assert_match(/pivot: index: "r" holds values that cannot be put in order/, e.message)
  end

  def test_a_record_refusal_points_at_its_values
    g = CArray.struct { float64 :lat }
    e = assert_raise(ArgumentError) { CArray.fixlen_string(%w[ab]).is_in(CARecord.new(g, 2)) }
    assert_match(/to_type\(:object\) gives its values/, e.message)
    e = assert_raise(ArgumentError) { CArray.fixlen_string(%w[a]).locate_addr(CArray.const_string(%w[a])) }
    assert_match(/#to_string gives its strings/, e.message)
  end

  def test_a_categorical_cannot_be_ordered_by_its_codes
    c = CA_OBJECT(%w[b a c]).categorize
    e = assert_raise(ArgumentError) { c.min }
    assert_match(/order its values instead -- to_type\(:object\) gives its values/, e.message)
  end

  def test_sort_by_key_names_the_column_and_the_frame_way
    c = CA_OBJECT(%w[b a c]).categorize
    df = CAFrame.new("k" => c, "z" => CA_CMPLX128([1, 2, 3]), "i" => CA_INT64([0, 1, 2]))
    e = assert_raise(ArgumentError) { df.sort_by_key("i", "k") }
    assert_match(/sort_by_key: the column "k" cannot be sorted/, e.message)
    assert_match(/sort_by \{ \|f\| f\["k"\]\.to_type\(:object\) \}/, e.message)
    assert_equal [1, 0, 2], df.sort_by { |f| f["k"].to_type(:object) }["i"].to_a
    e = assert_raise(CArray::DataTypeError) { df.sort_by_key("z") }
    assert_match(/the column "z" cannot be sorted: a cmplx128 key has no order/, e.message)
  end

  def test_sort_addr_of_complex_is_a_data_type_error
    assert_raise(CArray::DataTypeError) { CA_CMPLX128([1, 2]).sort_addr }
  end

  def test_a_time_key_refuses_integers_the_same_way_from_either_side
    t = CArray.time(["2024-01-01", "2024-01-02"], unit: :D)
    i = CA_INT64([19723])
    [-> { t.is_in(i) }, -> { i.is_in(t) }, -> { t.locate_addr(i) },
     -> { i.locate_addr(t) }, -> { t.eq(i) }].each do |op|
      e = assert_raise(TypeError) { op.call }
      assert_match(/CATime cannot reconcile Integer/, e.message)
    end
  end

  def test_a_time_compared_with_object_times
    t = CArray.time(["2024-01-01", "2024-01-02"], unit: :D)
    assert_equal [true, false], t.eq(CA_OBJECT([Time.utc(2024, 1, 1), "2024-01-01"])).to_a
  end

  def test_a_time_conversion_speaks_of_times
    h = CArray.time(["2024-01-02T01"], unit: :h)
    e = assert_raise(ArgumentError) { CATimeUnitAlgebra.convert_instant!(h.parent, :h, :D) }
    assert_match(/cannot convert times in h to D without loss/, e.message)
  end

  def test_stack_rows_names_the_group
    f = CAFrame.new("st" => CA_OBJECT(%w[A A B]), "v" => CA_INT64([1, 2, 3]))
    e = assert_raise(ArgumentError) { f.stack_rows(by: "st") }
    assert_match(/st="A" has 2, st="B" has 1/, e.message)
  end
end

require "test/unit"
require "carray"

# CACategorical#contrast and CAFrame#contrast_columns: a categorical as
# numeric columns, one per category, for a model that takes numbers.
class TestContrast < Test::Unit::TestCase
  LABELS = %w[sun cloud rain].freeze

  def weather
    w = CA_OBJECT(%w[sun cloud rain sun rain cloud])
    w[3] = UNDEF
    w
  end

  def cat
    weather.categorize(labels: LABELS)
  end

  def test_dummy_leaves_the_first_label_out
    x = cat.contrast
    assert_equal CA_INT8, x.data_type
    assert_equal [6, 2], x.shape
    assert_equal [[0, 0], [1, 0], [0, 1], [UNDEF, UNDEF], [0, 1], [1, 0]], x.to_a
  end

  # Each kept column is the cell's equality with its label.
  def test_columns_agree_with_eq
    c = cat
    x = c.contrast(full: true)
    LABELS.each_with_index do |label, j|
      assert_equal c.eq(label).to_type(CA_INT8).to_a, x[nil, j].to_a, label
    end
  end

  def test_base_names_the_column_left_out
    assert_equal [[1, 0], [0, 0], [0, 1], [UNDEF, UNDEF], [0, 1], [0, 0]],
                 cat.contrast(base: "cloud").to_a
  end

  def test_full_rows_sum_to_one
    x = cat.contrast(full: true)
    assert_equal 3, x.shape[1]
    assert_equal [1, 1, 1, 1, 1], x[CA_INT64([0, 1, 2, 4, 5]), nil].sum(axis: 1).to_a
  end

  # The columns follow the labels: a category with no cells is a column of
  # zeros, so the same labels give the same columns.
  def test_a_category_with_no_cells_is_a_zero_column
    c = CA_OBJECT(%w[sun sun]).categorize(labels: LABELS)
    assert_equal [[0, 0], [0, 0]], c.contrast.to_a
    assert_equal [[1, 0, 0], [1, 0, 0]], c.contrast(full: true).to_a
  end

  def test_one_label_leaves_no_column
    c = CA_OBJECT(%w[a a]).categorize
    assert_equal [2, 0], c.contrast.shape
    assert_equal [[1], [1]], c.contrast(full: true).to_a
  end

  def test_from_codes_masked_and_sentinel_rows_are_masked
    codes = CA_UINT8([0, 255, 1])
    c = CACategorical.from_codes(codes, %w[a b])
    assert_equal [[0], [UNDEF], [1]], c.contrast.to_a
  end

  def test_refusals
    c = cat
    assert_raise(ArgumentError) { c.contrast(:helmert) }
    assert_raise(ArgumentError) { c.contrast(base: "snow") }
    assert_raise(ArgumentError) { c.contrast(base: "sun", full: true) }
    assert_raise(ArgumentError) { CA_OBJECT(%w[a]).categorize(labels: []).contrast }
    assert_raise(ArgumentError) { CA_OBJECT([["a", "b"], ["b", "a"]]).categorize.contrast }
  end

  # ---- CAFrame#contrast_columns ----

  def frame
    CAFrame.new("t" => CA_INT32([1, 2, 3, 4, 5, 6]), "weather" => weather,
                "y" => CA_FLOAT64([1, 2, 3, 4, 5, 6]))
  end

  # A column that is not a categorical is categorized with its labels in
  # ascending order (cloud, rain, sun), so the base is "cloud".
  def test_columns_take_the_place_of_the_column
    d = frame.contrast_columns("weather")
    assert_equal %w[t weather_rain weather_sun y], d.column_names
    assert_equal [0, 0, 1, UNDEF, 1, 0], d["weather_rain"].to_a
    assert_equal [1, 0, 0, UNDEF, 0, 0], d["weather_sun"].to_a
  end

  def test_base_does_not_depend_on_the_row_order
    a = frame.contrast_columns("weather").column_names
    b = frame[CA_INT64([5, 4, 3, 2, 1, 0])].contrast_columns("weather").column_names
    assert_equal a, b
  end

  def test_a_categorical_column_keeps_its_label_order
    df = CAFrame.new("w" => cat)
    assert_equal %w[w_cloud w_rain], df.contrast_columns("w").column_names
    assert_equal %w[w_sun w_cloud w_rain], df.contrast_columns("w", full: true).column_names
  end

  def test_columns_agree_with_contrast
    c = cat
    d = CAFrame.new("w" => c).contrast_columns("w", base: "rain")
    x = c.contrast(base: "rain")
    assert_equal x.to_a, d.to_ca.to_a
  end

  def test_into_names_the_columns
    d = frame.contrast_columns("weather", full: true, into: %w[a b c])
    assert_equal %w[t a b c y], d.column_names
  end

  def test_the_frame_is_left_alone
    df = frame
    df.contrast_columns("weather")
    assert_equal %w[t weather y], df.column_names
  end

  def test_frame_refusals
    df = frame
    assert_raise(ArgumentError) { df.contrast_columns("weather", into: %w[a]) }
    assert_raise(ArgumentError) { df.contrast_columns("weather", into: %w[a a]) }
    assert_raise(ArgumentError) { df.contrast_columns("weather", into: %w[t a]) }
    assert_raise(KeyError) { df.contrast_columns("nope") }
    taken = CAFrame.new("w" => cat, "w_rain" => CA_INT32([0] * 6))
    err = assert_raise(ArgumentError) { taken.contrast_columns("w") }
    assert_match(/into:/, err.message)
    wide = CAFrame.new("w" => CA_INT32([[1, 2], [3, 4]]))
    assert_raise(ArgumentError) { wide.contrast_columns("w") }
  end

  # The base is found among the labels by ==, as contrast finds it.
  def test_base_is_found_as_contrast_finds_it
    df = CAFrame.new("x" => CA_FLOAT64([1, 2, 3, 1]), "i" => CA_INT32([1, 2, 3, 1]))
    assert_equal %w[x_1.0 x_3.0 i], df.contrast_columns("x", base: 2).column_names
    assert_equal %w[x i_1 i_3], df.contrast_columns("i", base: 2.0).column_names
  end

  # A NaN label is found by NaN, as join and at match NaN keys.
  def test_nan_base
    c = CA_FLOAT64([1, Float::NAN, 1]).categorize(sort_labels: true)
    assert_equal [[1], [0], [1]], c.contrast(base: Float::NAN).to_a
    df = CAFrame.new("x" => CA_FLOAT64([1, Float::NAN, 2]))
    assert_equal %w[x_1.0 x_2.0], df.contrast_columns("x", base: Float::NAN).column_names
  end
end

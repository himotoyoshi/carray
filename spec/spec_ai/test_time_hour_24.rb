require "test/unit"
require "carray"

# Hour 24 is the end of the day, 24:00:00, and nothing past it: 24:30 used
# to roll into 00:30 of the next day.
class TestTimeHour24 < Test::Unit::TestCase
  def parse(cells, format)
    CAFrame.new("t" => CA_OBJECT(cells)).parse_to_time("t", format)["t"]
  end

  def test_a_format_reads_24_00_as_the_next_midnight
    assert_equal ["2024-02-14T00:00:00Z"],
                 parse(["13/02/2024 24:00"], "%d/%m/%Y %H:%M").to_a.map(&:to_s)
  end

  def test_a_format_does_not_read_past_24_00
    t = parse(["13/02/2024 24:30", "13/02/2024 24:00:01", "13/02/2024 23:59"],
              "%d/%m/%Y %H:%M")
    assert_equal [true, true, false], t.is_masked.to_a
  end

  def test_on_error_raise_names_the_cell
    df = CAFrame.new("t" => CA_OBJECT(["13/02/2024 24:30"]))
    assert_raise(ArgumentError) { df.parse_to_time("t", "%d/%m/%Y %H:%M", on_error: :raise) }
  end

  def test_infer_does_not_read_past_24_00
    df = CAFrame.new("t" => CA_OBJECT(["13/02/2024 24:30"]))
    assert_raise(ArgumentError) { df.parse_to_time("t", :infer) }
  end

  # The format reader in Ruby, for what the C reader does not take.
  def test_the_ruby_reader_agrees
    reader = ->(s) { CATimeLiteral.send(:parse_date_fields, s, "%d/%m/%Y %H:%M") }
    assert_equal 24, reader.("13/02/2024 24:00")[:hour]
    assert_raise(ArgumentError) { reader.("13/02/2024 24:30") }
    assert_raise(ArgumentError) { CATimeLiteral.send(:parse_date_fields, "2024-02-13 24:00:01", nil) }
  end
end

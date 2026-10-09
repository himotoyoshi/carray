# A boolean column goes to CSV as 1 / 0 and comes back with
# types: { name => :boolean }, which also reads true / false in any case.
# :infer takes true / false as boolean and leaves 0 / 1 as integers, and
# cast(name => :boolean) turns an integer column of 0 / 1 into a boolean.

require "test/unit"
require "carray"
require "tmpdir"

class TestFrameCsvBoolean < Test::Unit::TestCase

  def read(text, **kw)
    Dir.mktmpdir do |d|
      path = File.join(d, "a.csv")
      File.write(path, text)
      CAFrame.from_csv(path, **kw)
    end
  end

  def test_round_trip
    b = CA_BOOLEAN([1, 0, 1])
    b[2] = UNDEF
    text = CAFrame.new({ "b" => b }).to_csv(index: false)
    assert_equal "b\n1\n0\n\n", text
    back = read(text, types: { "b" => :boolean })["b"]
    assert_equal :boolean, back.data_type
    assert_equal [true, false, UNDEF], back.to_a
  end

  def test_words_in_any_case
    f = read("b\nTrue\nFALSE\n true \n\n", types: { "b" => :boolean })
    assert_equal [true, false, true, UNDEF], f["b"].to_a
  end

  def test_unreadable_follows_on_error
    assert_equal [true, false, UNDEF], read("b\n1\n0\nyes\n", types: { "b" => :boolean })["b"].to_a
    assert_raise(CAFrame::UnreadableColumn) do
      read("b\n1\n0\nyes\n", types: { "b" => :boolean }, on_error: :raise)
    end
  end

  def test_infer
    f = read("b,i\ntrue,1\nFalse,0\n,1\n", types: :infer)
    assert_equal :boolean, f["b"].data_type
    assert_equal [true, false, UNDEF], f["b"].to_a
    assert_equal :int64, f["i"].data_type
  end

  def test_cast_integer_column
    i = CA_INT64([0, 1, 1, 2])
    i[1] = UNDEF
    f = CAFrame.new({ "i" => i }).cast("i" => :boolean)
    assert_equal [false, UNDEF, true, UNDEF], f["i"].to_a
    assert_raise(CAFrame::UnreadableColumn) do
      CAFrame.new({ "i" => CA_INT64([0, 2]) }).cast("i" => :boolean, on_error: :raise)
    end
  end
end

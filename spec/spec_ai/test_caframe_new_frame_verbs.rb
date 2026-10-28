# frozen_string_literal: true

require "test/unit"
require "carray"

# set_index / reset_index / cast / promote / parse_to_time / to_time return a
# new frame and leave the receiver as it is. The new frame shares the columns
# it did not replace, so a write to a cell through it reaches the receiver;
# copy cuts that.
class TestCAFrameNewFrameVerbs < Test::Unit::TestCase
  def frame
    CAFrame.new("t" => CA_INT64([0, 1]), "s" => CArray.string(%w[2024-01-01 2024-01-02]),
                "v" => CA_FLOAT64([1.5, 2.5]))
  end

  def test_the_receiver_is_left_as_it_is
    df = frame
    { set_index: ["t"], cast: [{ "v" => :float32 }], promote: [:object],
      parse_to_time: ["s"], to_time: ["t"] }.each do |verb, args|
      out = df.public_send(verb, *args)
      assert_not_same df, out, verb.to_s
      assert_nil df.index, verb.to_s
      assert_equal({ "t" => :int64, "s" => CAString, "v" => :float64 }, df.data_types, verb.to_s)
    end
    indexed = df.set_index("t")
    indexed.reset_index
    assert_equal "t", indexed.axis_name
  end

  def test_a_write_through_the_new_frame_reaches_shared_columns
    df  = frame
    out = df.set_index("t")
    out["v"][0] = 9.0
    assert_equal 9.0, df["v"][0]
    out = df.cast("s" => :time)
    out["v"][1] = 8.0
    assert_equal 8.0, df["v"][1]
  end

  def test_a_converted_column_is_its_own
    df  = frame
    out = df.cast("v" => :float32)
    out["v"][0] = 7.0
    assert_equal 1.5, df["v"][0]
  end

  def test_copy_cuts_the_connection
    df  = frame
    out = df.set_index("t").copy
    out["v"][0] = 9.0
    assert_equal 1.5, df["v"][0]
  end

  def test_fill_and_mask_eq_still_edit_the_receiver
    df = frame
    assert_same df, df.mask_eq("v", 1.5)
    assert_equal 1, df["v"].count_masked
    assert_same df, df.fill("v", 0.0)
    assert_equal [0.0, 2.5], df["v"].to_a
  end
end

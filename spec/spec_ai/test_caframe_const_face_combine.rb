$:.unshift File.expand_path("../../ext", __dir__)
$:.unshift File.expand_path("../../lib", __dir__)
require "test/unit"
require "carray"

# A Face that cannot hold new values (CACategorical, CAConstString) in the
# verbs that read a column by rows, or refuse it when several frames meet.
class TestCAFrameConstFaceCombine < Test::Unit::TestCase

  def text (*values)
    CAFrame.new("x" => values)["x"].to_const_string
  end

  def frame (col)
    CAFrame.new("g" => CA_INT32([0, 0, 1, 1]), "v" => col)
  end

  def test_group_lag_keeps_a_categorical
    col = CA_OBJECT(%w[a b c a]).categorize
    out = frame(col).group_by("g").lag("v")
    assert_kind_of CACategorical, out
    assert_equal [UNDEF, "a", UNDEF, "c"], out.to_a
  end

  def test_group_lag_keeps_a_const_string
    out = frame(text("p", "q", "r", "p")).group_by("g").lag("v")
    assert_kind_of CAConstString, out
    assert_equal [UNDEF, "p", UNDEF, "r"], out.to_a
  end

  def test_group_lag_of_a_negative_step_and_of_every_column
    d = frame(CA_OBJECT(%w[a b c a]).categorize)
    assert_equal ["b", UNDEF, "a", UNDEF], d.group_by("g").lag("v", n: -1).to_a
    assert_kind_of CACategorical, d.group_by("g").lag["v"]
  end

  def test_group_lag_of_a_masked_cell_and_a_row_in_no_group
    col = CA_OBJECT(%w[a b c a]).categorize
    col = col[CA_INT32([0, 1, 2, 3])].mask_where(CA_BOOLEAN([true, false, false, false]))
    d = CAFrame.new("g" => CA_OBJECT([0, 0, 0, UNDEF]), "v" => col)
    assert_equal [UNDEF, UNDEF, "b", UNDEF], d.group_by("g").lag("v").to_a
  end

  def test_group_lag_gives_the_rows_it_gave_as_an_object_array
    col = CA_OBJECT(%w[a b c a b c]).categorize
    d = CAFrame.new("g" => CA_INT32([1, 0, 1, 0, 1, 0]), "v" => col)
    assert_equal d.group_by("g").lag("v", n: 2).to_a,
                 CAFrame.new("g" => d["g"], "v" => CA_OBJECT(%w[a b c a b c])).group_by("g").lag("v", n: 2).to_a
  end

  def test_the_frame_verbs_refuse_by_their_own_name_and_the_column
    d = frame(text("p", "q", "r", "p"))
    { "meld" => -> { CAFrame.meld(d, d) },
      "concatenate" => -> { CAFrame.concatenate(d, d) },
      "stack" => -> { CAFrame.stack(d, d) } }.each do |verb, call|
      err = assert_raise(ArgumentError, verb) { call.call }
      assert_match(/\A#{verb}: column "v": CAConstString state is not portable/, err.message)
      assert_no_match(/promote_list/, err.message)
    end
  end

  def test_another_refusal_passes_through
    a = CAFrame.new("t" => CArray.time(["2024-01-01"], unit: :D))
    b = CAFrame.new("t" => CArray.time(["2024-01-01"], unit: :h))
    err = assert_raise(ArgumentError) { CAFrame.meld(a, b) }
    assert_match(/\Ameld: column "t"/, err.message)
  end

end

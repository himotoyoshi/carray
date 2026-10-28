# CAFrame#strip_mask -- a new frame with the masked cells filled, the
# frame itself left as it is.

require "test/unit"
require "carray"
require "carray/categorical"

class TestCAFrameStripMask < Test::Unit::TestCase

  def col(vals, *masked, type: :float64)
    c = CArray.new(type, [vals.size]) { vals }
    masked.each { |i| c[i] = UNDEF }
    c
  end

  def frame
    CAFrame.new("x" => col([1.0, 2.0, 3.0, 4.0], 1),
                "n" => col([1, 2, 3, 4], type: :int32),
                "s" => col(["a", "b", "c", "d"], 2, type: :object))
  end

  def test_one_value_fills_every_masked_column_and_returns_a_new_frame
    df = frame
    out = df.strip_mask(0)
    assert_not_same(df, out)
    assert_equal([1.0, 0.0, 3.0, 4.0], out["x"].to_a)
    assert_equal(["a", "b", 0, "d"], out["s"].to_a)
    assert_equal([1.0, UNDEF, 3.0, 4.0], df["x"].to_a)
    assert_equal(["a", "b", UNDEF, "d"], df["s"].to_a)
  end

  # NaN cannot go into an integer column; a complete one is not asked to.
  def test_one_value_leaves_a_complete_column_alone
    df = frame
    out = df.strip_mask(Float::NAN)
    assert_true(out["x"][1].nan?)
    assert_same(df["n"], out["n"])
  end

  def test_a_masked_column_that_cannot_take_the_value_is_named
    df = frame
    df["n"][0] = UNDEF
    e = assert_raise(FloatDomainError) { df.strip_mask(Float::NAN) }
    assert_match(/column "n" \(int32\) cannot take NaN/, e.message)
  end

  def test_hash_fills_the_named_columns_each_its_own_value
    df = frame
    out = df.strip_mask("x" => -1.0, "s" => "?")
    assert_equal([1.0, -1.0, 3.0, 4.0], out["x"].to_a)
    assert_equal(["a", "b", "?", "d"], out["s"].to_a)
    assert_equal(out, df.strip_mask({ "x" => -1.0, "s" => "?" }))
  end

  def test_a_named_column_is_filled_whatever_it_holds
    e = assert_raise(FloatDomainError) { frame.strip_mask("n" => Float::NAN) }
    assert_match(/column "n"/, e.message)
  end

  def test_a_positional_symbol_is_a_value
    out = frame.strip_mask("s" => :na)
    assert_equal(["a", "b", :na, "d"], out["s"].to_a)
  end

  def test_method_for_every_column
    out = frame.strip_mask(method: :forward)
    assert_equal([1.0, 1.0, 3.0, 4.0], out["x"].to_a)
    assert_equal(["a", "b", "b", "d"], out["s"].to_a)
    out = frame.strip_mask(method: :bfill)
    assert_equal([1.0, 3.0, 3.0, 4.0], out["x"].to_a)
  end

  def test_method_hash
    out = frame.strip_mask(method: { "x" => :linear, "s" => :backward })
    assert_equal([1.0, 2.0, 3.0, 4.0], out["x"].to_a)
    assert_equal(["a", "b", "d", "d"], out["s"].to_a)
  end

  def test_linear_interpolates_against_the_index
    df = CAFrame.new({ "x" => col([1.0, 0.0, 3.0, 4.0], 1) },
                     index: CA_FLOAT64([0, 1, 3, 4]), axis_name: "t")
    out = df.strip_mask(method: :linear)
    assert_in_delta(1.0 + 2.0 / 3.0, out["x"][1], 1e-12)
    assert_equal(UNDEF, df["x"][1])
    assert_equal(df.index.to_a, out.index.to_a)
  end

  def test_linear_on_a_time_column_keeps_the_face
    t = CArray.time(["2026-01-01", "2026-01-02", "2026-01-03"])
    t[1] = UNDEF
    df = CAFrame.new({ "d" => t }, index: CA_FLOAT64([0, 1, 2]), axis_name: "i")
    out = df.strip_mask(method: :linear)
    assert_kind_of(CATime, out["d"])
    assert_equal("2026-01-02", out["d"][1].to_s)
    assert_true(df["d"].any_masked?)
  end

  def test_linear_on_a_text_column_is_refused_by_name
    e = assert_raise(ArgumentError) { frame.strip_mask(method: { "s" => :linear }) }
    assert_match(/column "s"/, e.message)
  end

  def test_nd_column_is_filled_down_the_rows
    v = CArray.float64(3, 2).seq
    v[1, 0] = UNDEF
    out = CAFrame.new("v" => v).strip_mask(method: :forward)
    assert_equal([[0.0, 1.0], [0.0, 3.0], [4.0, 5.0]], out["v"].to_a)
  end

  def test_categorical_column
    c = CA_OBJECT(["a", "b", "a"])
    c[1] = UNDEF
    df = CAFrame.new("c" => c.categorize)
    assert_equal(["a", "a", "a"], df.strip_mask("c" => "a")["c"].to_a)
    assert_equal(["a", "a", "a"], df.strip_mask(method: :forward)["c"].to_a)
  end

  def test_a_frozen_frame_gives_a_filled_copy
    df = frame.freeze
    assert_equal([1.0, 0.0, 3.0, 4.0], df.strip_mask("x" => 0.0)["x"].to_a)
  end

  def test_refusals
    df = frame
    assert_raise(ArgumentError) { df.strip_mask }
    assert_raise(ArgumentError) { df.strip_mask(0, method: :forward) }
    assert_raise(ArgumentError) { df.strip_mask("x" => 0, method: :forward) }
    assert_raise(ArgumentError) { df.strip_mask(method: :nearest) }
    assert_raise(ArgumentError) { df.strip_mask({}) }
    assert_raise(KeyError) { df.strip_mask("zz" => 0) }
    assert_raise(TypeError) { df.strip_mask(x: 0) }
  end

  def test_the_index_is_not_filled
    i = CA_FLOAT64([0, 1, 2])
    i[1] = UNDEF
    df = CAFrame.new({ "x" => col([1.0, 2.0, 3.0]) }, index: i, axis_name: "t")
    assert_raise(KeyError) { df.strip_mask("t" => 0.0) }
    assert_equal(UNDEF, df.strip_mask(0.0).index[1])
  end
end

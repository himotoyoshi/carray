require "test/unit"
require "carray"

# CAFrame#protect makes a frame read-only: frozen like +freeze+, and the cells
# and masks of every column and of the index refuse writes made through it.
# The arrays the frame was built from stay writable.
class TestCAFrameProtect < Test::Unit::TestCase

  def setup
    @a = CArray.int32(3).seq!
    @a.mask = 0
    @f = CA_FLOAT64([1.5, 2.5, 3.5])
    @t = CArray.time(["2024-01-01", "2024-01-02", "2024-01-03"])
    @c = CA_OBJECT(["x", "y", "x"]).categorize
    @s = CArray.const_string(%w[p q r])
    @df = CAFrame.new({ "a" => @a, "f" => @f, "t" => @t, "c" => @c, "s" => @s },
                      index: CA_INT32([10, 20, 30]))
  end

  def test_returns_self_frozen_and_protected
    assert_equal false, @df.protected?
    assert_same @df, @df.protect
    assert_equal true, @df.frozen?
    assert_equal true, @df.protected?
  end

  def test_columns_and_index_are_read_only
    @df.protect
    @df.column_names.each { |n| assert_equal true, @df[n].read_only?, n }
    assert_equal true, @df.index.read_only?
  end

  def test_columns_keep_their_class
    @df.protect
    assert_kind_of CATime, @df["t"]
    assert_kind_of CACategorical, @df["c"]
    assert_kind_of CAConstString, @df["s"]
  end

  def test_cell_and_mask_writes_are_refused
    @df.protect
    assert_raise(RuntimeError) { @df["a"][0] = 9 }
    assert_raise(RuntimeError) { @df["a"][0] = UNDEF }
    assert_raise(RuntimeError) { @df["a"].mask[1] = true }
    assert_raise(RuntimeError) { @df["a"].unmask }
    assert_raise(RuntimeError) { @df["t"][0] = @t[1] }
    assert_raise(RuntimeError) { @df.index[0] = 1 }
    assert_equal [0, 1, 2], @a.to_a
    assert_equal [false, false, false], @a.mask.to_a
  end

  def test_frame_edits_are_refused_as_frozen
    @df.protect
    assert_raise(FrozenError) { @df["z"] = CA_INT32([1, 2, 3]) }
    assert_raise(FrozenError) { @df[0] = UNDEF }
    assert_raise(FrozenError) { @df.fill("f", 0) }
  end

  def test_source_arrays_stay_writable_and_show_through
    @df.protect
    assert_equal false, @a.read_only?
    assert_equal false, @f.read_only?
    @a[0] = 7
    @f[1] = UNDEF
    assert_equal 7, @df["a"][0]
    assert_equal true, @df["f"].mask[1]
  end

  def test_view_derived_frames_refuse_cell_writes
    @df.protect
    assert_raise(RuntimeError) { @df.filter { |f| f["f"] > 2 }["f"][0] = 0 }
    assert_raise(RuntimeError) { @df.select("f")["f"][0] = 0 }
    assert_raise(RuntimeError) { @df[0..1]["f"][0] = 0 }
    assert_equal false, @df.select("f").frozen?
  end

  def test_copy_is_writable
    @df.protect
    x = @df.copy
    assert_equal false, x.protected?
    x["f"][0] = 0.0
    assert_equal 0.0, x["f"][0]
    assert_equal 1.5, @f[0]
  end

  def test_dup_is_not_protected_clone_is
    @df.protect
    d = @df.dup
    assert_equal false, d.protected?
    d["z"] = CA_INT32([1, 2, 3])
    assert_equal true, d["f"].read_only?
    assert_equal true, @df.clone.protected?
  end

  def test_protect_twice_is_a_no_op
    @df.protect
    f = @df["f"]
    assert_same @df, @df.protect
    assert_same f, @df["f"]
  end

  def test_frozen_frame_cannot_be_protected
    @df.freeze
    assert_raise(FrozenError) { @df.protect }
    assert_equal false, @df.protected?
  end

end

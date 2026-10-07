require "test/unit"
require "carray"

# The mask of a read-only array is read-only too.  read-only travels along
# parent links, and an array reaches its mask through no parent link, so
# CArray#mask passes the flag on when it hands the mask out.
class TestReadOnlyMask < Test::Unit::TestCase

  def masked (values)
    a = CArray.int32(values.size)
    values.each_with_index { |x, i| a[i] = x.nil? ? UNDEF : x }
    a
  end

  def test_mask_of_a_read_only_array
    a = masked([1, nil, 3])
    a.set_read_only_flag
    assert_true(a.mask.read_only?)
    assert_raise(RuntimeError) { a.mask[0] = true }
    assert_equal([false, true, false], a.mask.to_a)
  end

  def test_mask_of_a_view_of_a_read_only_array
    a = masked([1, nil, 3])
    a.set_read_only_flag
    assert_raise(RuntimeError) { a[0..1].mask[0] = true }
    assert_equal([false, true, false], a.mask.to_a)
  end

  # from_codes keeps codes and mask in step; writing the mask of the
  # read-only codes would bypass that.
  def test_mask_of_categorical_codes
    codes = CArray.int8(3) { 0 }
    codes[1] = UNDEF
    c = CACategorical.from_codes(codes, ["x", "y"])
    assert_raise(RuntimeError) { c.codes.mask[0] = true }
    assert_equal(["x", UNDEF, "x"], c.to_a)
  end

  def test_mask_of_a_writable_array_stays_writable
    a = masked([1, nil, 3])
    a.mask[0] = true
    assert_equal([true, true, false], a.mask.to_a)
    b = masked([1, nil, 3])
    b[0..1].mask[0] = true
    assert_equal([true, true, false], b.mask.to_a)
  end

  def test_copy_of_a_read_only_array_is_writable
    a = masked([1, nil, 3])
    a.set_read_only_flag
    a.mask
    b = a.copy
    b.mask[2] = true
    assert_equal([false, true, true], b.mask.to_a)
  end

end

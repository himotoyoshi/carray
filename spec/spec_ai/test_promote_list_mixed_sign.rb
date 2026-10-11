require "test/unit"
require "carray"

# Arrays joined into one (concatenate, stack, CAFrame.concatenate) keep their
# values: a list mixing signed and unsigned integers takes a type that holds
# both, the type equality matches such a pair in.
class TestPromoteListMixedSign < Test::Unit::TestCase

  def test_concatenate_keeps_negative_values
    a = CArray.concatenate([CA_UINT8([255]), CA_INT8([-1])])
    assert_equal :int16, a.data_type
    assert_equal [255, -1], a.to_a
  end

  def test_stack_keeps_negative_values
    assert_equal [[255], [-1]], CArray.stack([CA_UINT8([255]), CA_INT8([-1])]).to_a
  end

  def test_64_bit_pair_lands_in_object
    a = CArray.concatenate([CA_UINT64([2**64 - 1]), CA_INT64([-1])])
    assert_equal :object, a.data_type
    assert_equal [2**64 - 1, -1], a.to_a
  end

  def test_same_signedness_is_unchanged
    assert_equal :uint16, CArray.concatenate([CA_UINT8([1]), CA_UINT16([2])]).data_type
    assert_equal :int16,  CArray.concatenate([CA_INT8([1]), CA_INT16([2])]).data_type
    assert_equal :float32,
                 CArray.concatenate([CA_INT8([1]), CA_UINT8([2]), CA_FLOAT32([1])]).data_type
  end

  def test_frame_concatenate_keeps_two_keys_apart
    f = ->(k) { CAFrame.new("k" => k, "v" => CA_INT32([1])) }
    c = CAFrame.concatenate(f.(CA_UINT8([255])), f.(CA_INT8([-1])))
    assert_equal [255, -1], c["k"].to_a
    assert_equal 2, c.group_by("k").sum.nrow
  end

  # An integer of 32 bits or more beside a float32 is matched and joined in
  # float64: float32 holds integers exactly only up to 2**24.
  def test_wide_integers_beside_float32_keep_their_values
    assert_equal [false], CA_INT64([16_777_217]).is_in(CA_FLOAT32([16_777_216.0])).to_a
    assert_equal [false], CA_INT32([16_777_217]).is_in(CA_FLOAT32([16_777_216.0])).to_a
    assert_equal [true],  CA_INT32([16_777_216]).is_in(CA_FLOAT32([16_777_216.0])).to_a
    c = CArray.concatenate([CA_INT32([16_777_217]), CA_FLOAT32([1.5])])
    assert_equal :float64, c.data_type
    assert_equal [16_777_217.0, 1.5], c.to_a
    assert_equal :float32, CArray.concatenate([CA_INT16([1]), CA_FLOAT32([1.5])]).data_type
  end
end

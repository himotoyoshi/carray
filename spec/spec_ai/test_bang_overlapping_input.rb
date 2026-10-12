require "test/unit"
require "carray"

# A bang operation whose input shares memory with its target answers what
# the non-bang form answers: the input is read as it was before the
# operation, not with the cells the operation has already written.
class TestBangOverlappingInput < Test::Unit::TestCase

  def bang_matches_plain (target, op, *inputs)
    expected = target.send(op.to_s.chomp("!"), *inputs).to_a
    target.send(op, *inputs)
    assert_equal expected, target.to_a, op.to_s
  end

  def test_binop_input_shifted_ahead_of_target
    [:int32, :float64].each do |t|
      [:add!, :sub!, :mul!, :div!].each do |op|
        a = CArray.new(t, [6]).seq!(1)
        bang_matches_plain(a[1..5], op, a[0..4])
      end
    end
  end

  def test_binop_input_shifted_behind_target
    a = CArray.int32(6).seq!
    bang_matches_plain(a[0..4], :add!, a[1..5])
  end

  def test_binop_rows_of_a_matrix
    b = CArray.int32(3, 4).seq!
    bang_matches_plain(b[1..2, nil], :add!, b[0..1, nil])
  end

  def test_binop_running_sum_does_not_appear
    a = CA_INT32([0, 1, 2, 3, 4, 5])
    a[1..5].add!(a[0..4])
    assert_equal [0, 1, 3, 5, 7, 9], a.to_a
  end

  def test_binop_target_as_its_own_input
    a = CArray.int32(5).seq!
    a.add!(a)
    assert_equal [0, 2, 4, 6, 8], a.to_a
  end

  def test_binop_reversed_input
    a = CA_INT32([0, 1, 2, 3, 4])
    a.add!(a.flip(0))
    assert_equal [4, 4, 4, 4, 4], a.to_a
  end

  def test_binop_masked_overlapping_input
    a = CA_INT32([0, 1, 2, 3, 4, 5])
    a[0] = UNDEF
    expected = (a[1..5] + a[0..4]).to_a
    a[1..5].add!(a[0..4])
    assert_equal expected, a[1..5].to_a
  end

  def test_triop_input_shifted_ahead_of_target
    a = CArray.float64(6).seq!(1)
    bang_matches_plain(a[1..5], :fma!, a[0..4], a[0..4])
  end

  # Two inputs that cannot be read in place send a large triop through
  # the per-chunk gather; an input sharing the target's memory must not.
  def test_triop_large_reversed_inputs
    n = 100_000
    a = CArray.float64(n + 1).seq!
    r = a[0...n].flip(0)
    bang_matches_plain(a[1..n], :fma!, r, r)
  end

  def test_input_from_another_array_is_unaffected
    a = CArray.int32(5).seq!
    b = CArray.int32(5).seq!(10)
    a.add!(b)
    assert_equal [10, 12, 14, 16, 18], a.to_a
  end

end

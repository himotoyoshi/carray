require "test/unit"
require "carray"

# An operator operand that exports MemoryView and also defines to_ca is taken
# through to_ca, the order wrap_readonly uses.  The MemoryView carries only
# the values buffer; to_ca can carry what the object knows besides (an Arrow
# array's nulls as a mask).  Uses MVBorrower::Producer, the in-repo producer
# mock; skipped when it is not built.

borrower_dir = File.expand_path("ext_memory_view_test", __dir__)
$LOAD_PATH.unshift(borrower_dir)
begin
  require "mv_borrower"
rescue LoadError
  warn "Skipping test_mv_operand_to_ca: mv_borrower.bundle not built."
  return
end

class TestMVOperandToCa < Test::Unit::TestCase

  # A producer of int32 values [1, 2, 3].  With `nulls:`, it also answers
  # to_ca with those cells masked, the way an Arrow array with nulls does.
  def producer (nulls: nil, to_ca: :masked)
    prod = MVBorrower::Producer.new([1, 2, 3].pack("l*"), "l", 4)
    case to_ca
    when :masked
      prod.define_singleton_method(:to_ca) do
        ca = CArray.int32(3) { |i| i + 1 }
        (nulls || []).each { |i| ca[i] = UNDEF }
        ca
      end
    when :not_a_carray
      prod.define_singleton_method(:to_ca) { [1, 2, 3] }
    end
    prod
  end

  def test_operand_with_to_ca_keeps_its_mask
    r = CArray.int32(3) { 10 } + producer(nulls: [1])
    assert_equal([11, UNDEF, 13], r.to_a)
  end

  def test_comparison_keeps_the_mask
    r = CArray.int32(3) { |i| i + 1 }.eq(producer(nulls: [0]))
    assert_equal([UNDEF, true, true], r.to_a)
  end

  def test_in_place_operator_keeps_the_mask
    a = CArray.int32(3) { 10 }
    a.add!(producer(nulls: [2]))
    assert_equal([11, 12, UNDEF], a.to_a)
  end

  def test_lazy_operand_keeps_the_mask
    r = (CArray.int32(3) { 10 }.lazy + producer(nulls: [1])).to_ca
    assert_equal([11, UNDEF, 13], r.to_a)
  end

  def test_operand_without_to_ca_goes_through_memory_view
    r = CArray.int32(3) { 10 } + producer(to_ca: nil)
    assert_equal([11, 12, 13], r.to_a)
  end

  def test_to_ca_that_returns_no_carray_is_refused
    assert_raise(TypeError) { CArray.int32(3) + producer(to_ca: :not_a_carray) }
  end

  # Only MemoryView producers are asked for to_ca, so a Range is still not
  # an operand.
  def test_range_is_still_not_an_operand
    assert_raise(TypeError) { CArray.int32(3) + (0..2) }
  end

  # The operators of CATime and CATimedelta take their operand the same way:
  # a producer whose to_ca gives a CATimedelta (an Arrow duration array) is
  # a duration.
  def duration_producer
    prod = MVBorrower::Producer.new([5, 7].pack("q*"), "q", 8)
    prod.define_singleton_method(:to_ca) { CATimedelta.wrap(CArray.int64(2) { |i| [5, 7][i] }, unit: :ms) }
    prod
  end

  def test_timedelta_operators_take_the_operand_through_to_ca
    td = CATimedelta.wrap(CArray.int64(2) { 10 }, unit: :ms)
    assert_equal([15, 17], (td + duration_producer).ticks.to_a)
    assert_equal([5, 3], (td - duration_producer).ticks.to_a)
    assert_equal([2, 1], (td / duration_producer).to_a)
  end

  def test_time_operators_take_the_operand_through_to_ca
    t = CATime.wrap(CArray.int64(2) { 1_000 }, unit: :ms)
    assert_equal([1_005, 1_007], (t + duration_producer).ticks.to_a)
    assert_equal([995, 993], (t - duration_producer).ticks.to_a)
  end

  def test_time_operator_names_the_operand_it_was_given
    t = CATime.wrap(CArray.int64(2) { 1_000 }, unit: :ms)
    error = assert_raise(TypeError) { t + producer(nulls: [0]) }
    assert_match(/MVBorrower::Producer/, error.message)
  end

end

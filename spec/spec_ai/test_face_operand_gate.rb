require "test/unit"
require "carray"

# The Face gate asks "is your storage your surface?" of the receiver. It used
# to ask nothing of the operand: a COMPARABLE receiver stripped any Face handed
# to it and compared that Face's encoding. Where the two encodings happened to
# be the same width, the comparison answered, wrongly and without an error.
#
# The width coincidence needs no contrivance: a CAConstString cell is a
# 16-byte (start, end) pair, and a CAFixlenString column whose longest value is
# 16 bytes has 16-byte cells too -- from the default width, with no bytes:.
class TestFaceOperandGate < Test::Unit::TestCase

  def codes   # 16-byte cells, by auto width
    CArray.fixlen_string(%w[AAPL MSFT BERKSHIRE_HATHAW])
  end

  def allow
    CArray.const_string(%w[AAPL GOOG])
  end

  def test_the_widths_really_do_coincide
    assert_equal 16, codes.bytes
    assert_equal 16, allow.bytes
  end

  # ---- the operand side ------------------------------------------------

  { :is_in        => ->(a, b) { a.is_in(b) },
    :count        => ->(a, b) { a.count(b) },
    :intersection => ->(a, b) { a.intersection(b) },
    :union        => ->(a, b) { a.union(b) },
    :difference   => ->(a, b) { a.difference(b) },
    :search       => ->(a, b) { a.search(b) },
    :bsearch      => ->(a, b) { a.bsearch(b) },
    :locate_addr  => ->(a, b) { a.locate_addr(b) },
  }.each do |name, op|
    define_method("test_#{name}_refuses_a_const_string_operand") do
      err = assert_raise(ArgumentError) { op.call(codes, allow) }
      assert_match(/CAConstString/, err.message)
    end
  end

  # ---- and the same question, asked so it can be answered --------------

  def test_converting_the_operand_gives_the_right_answer
    assert_equal [true, false, false], codes.is_in(allow.to_string).to_a
    assert_equal %w[AAPL], codes.intersection(allow.to_string).to_a
    assert_equal [0, UNDEF, UNDEF], codes.locate_addr(allow.to_string).to_a
  end

  # ---- combinations that were already right stay right -----------------

  def test_plain_and_comparable_operands_are_untouched
    assert_equal [true, false, false], codes.is_in(%w[AAPL]).to_a
    assert_equal [true, false, false], codes.is_in(CArray.string(%w[AAPL])).to_a
    assert_equal [true, false, false],
                 codes.is_in(CArray.fixlen_string(%w[AAPL], bytes: 16)).to_a
    assert_equal [true, false],
                 CArray.string(%w[AAPL MSFT]).is_in(CArray.fixlen_string(%w[AAPL], bytes: 4)).to_a
  end

  def test_numeric_paths_are_untouched
    a = CArray.int32(3) { |i| i }
    assert_equal [false, true, true], a.is_in([1, 2]).to_a
    assert_equal 1, a.count(1)
    assert_equal [UNDEF, 0, 1], a.locate_addr(CArray.int32(2) { |i| i + 1 }).to_a
  end

  def test_a_unit_bearing_face_still_reconciles_through_to_comparable
    t = CArray.time(%w[2026-01-01 2026-01-02], unit: :D)
    assert_equal [true, false], t.is_in(CArray.time(%w[2026-01-01], unit: :D)).to_a
    # cross-unit is what to_comparable is for: same instant, coarser unit
    assert_equal [true, false], t.is_in(CArray.time(%w[2026-01-01], unit: :h)).to_a
  end

  # CAConstString and CACategorical answer the family through their own Ruby
  # overrides, which fire when they are the receiver. That is unaffected; the
  # gap was that the overrides cannot fire when they are the argument.
  def test_the_const_string_overrides_still_answer
    assert_equal [true, false], allow.is_in(codes).to_a
    assert_equal %w[AAPL GOOG], allow.unique.to_a
    assert_equal 2, allow.nunique
    assert_equal [0, UNDEF], allow.locate_addr(codes).to_a
  end

  def test_a_categorical_still_answers
    assert_equal %w[a b], CArray.string(%w[a b a]).categorize.unique.to_a
  end

end

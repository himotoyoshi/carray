require "test/unit"
require "carray"

# A Face answers an operator by its own values (a label, an instant, a
# String) and refuses what it can't answer.  With a Face among the operands
# of a lazy operator, the answer is the eager one: the lazy kernels read the
# storage, where a categorical is its codes and a CAConstString its offsets.

class TestLazyFaceOperands < Test::Unit::TestCase

  def answer (f)
    r = f.()
    r.to_a
  rescue => e
    e.class
  end

  def test_a_lazy_operand_with_a_face_answers_as_the_eager_one
    tm    = CArray.time(["2024-01-01", "2024-01-02"], unit: :D)
    cat   = CA_OBJECT(%w[a b]).categorize
    cs    = CArray.const_string(%w[a b])
    o     = CA_OBJECT(%w[a b])
    times = CA_OBJECT([Time.utc(2024, 1, 1), Time.utc(2024, 1, 2)])
    i64   = CA_INT64([1, 2])
    nums  = CA_OBJECT([1, 2])
    {
      "o.eq(cat)"      => [-> { o.eq(cat) },        -> { o.lazy.eq(cat) }],
      "fuse"           => [-> { o.eq(cat) },        -> { CArray.fuse { o.eq(cat) } }],
      "o.eq(cs)"       => [-> { o.eq(cs) },         -> { o.lazy.eq(cs) }],
      "o + cs"         => [-> { o + cs },           -> { o.lazy + cs }],
      "times.eq(tm)"   => [-> { times.eq(tm) },     -> { times.lazy.eq(tm) }],
      "times < tm"     => [-> { times < tm },       -> { times.lazy < tm }],
      "cat % nums"     => [-> { cat % nums },       -> { cat % nums.lazy }],
      "cat + o"        => [-> { cat + o },          -> { cat + o.lazy }],
      "cs.eq(o)"       => [-> { cs.eq(o) },         -> { cs.eq(o.lazy) }],
      "tm.eq(i64)"     => [-> { tm.eq(i64) },       -> { tm.eq(i64.lazy) }],
    }.each do |name, (eager, lazy)|
      assert_equal answer(eager), answer(lazy), name
    end
    assert_equal [true, true], o.lazy.eq(cat).to_a
    assert_equal %w[a b], (cat % nums.lazy).to_a
  end

  # A CAConstString compared with another array compares Strings.
  def test_a_const_string_eq_another_array
    cs = CArray.const_string(["a", nil, "c"])
    assert_equal [true, UNDEF, true], cs.eq(CA_OBJECT(%w[a b c])).to_a
    assert_equal [true, UNDEF, true], cs.eq(CArray.string(%w[a b c])).to_a
    assert_equal [true, UNDEF, false], cs.eq(CArray.const_string(%w[a b x])).to_a
  end

  # Without a Face the operator is still lazy.
  def test_without_a_face_the_operator_stays_lazy
    assert_kind_of CABinOp, CA_INT32([1, 2]).lazy + 1
    assert_kind_of CABinCmp, CA_INT32([1, 2]).lazy.eq(CA_INT32([1, 3]))
  end

end

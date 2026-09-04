require "test/unit"
require "carray"
require "stringio"
require "tempfile"

# CArray can always walk an expression, so nothing has to be registered to
# compute one and nothing changes when nothing is.  A registered evaluator
# is a second way to the same answer -- it is asked, and it may decline.
class TestExpressionEvaluator < Test::Unit::TestCase

  BIG   = 20_000     # above the threshold
  SMALL = 100        # below it

  def setup
    @a = CArray.float64(BIG) { |i| i.to_f }
    @b = CArray.float64(BIG) { |i| i + 1.0 }
    @asked = []
    CArray.expression_evaluator = nil
  end

  def teardown
    CArray.expression_evaluator = nil
  end

  # Fills the output with a value nothing else would produce, so a test can
  # tell which side computed the answer.
  def answering (mark = -1.0)
    asked = @asked
    evaluator = Object.new
    evaluator.define_singleton_method(:call) do |plan, out|
      asked << plan
      out[] = mark
      true
    end
    evaluator
  end

  def declining
    asked = @asked
    evaluator = Object.new
    evaluator.define_singleton_method(:call) { |plan, out| asked << plan ; false }
    evaluator
  end

  # -- nothing registered ------------------------------------------------

  def test_without_one_the_walk_computes_it
    assert_equal (@a + @b).to_a, CArray.fuse { @a + @b }.to_ca.to_a
  end

  def test_and_the_plan_machinery_is_not_even_loaded
    # In a process of its own, since another test here registers one.
    script = <<~RUBY
      require "carray"
      a = CArray.float64(50_000) { |i| i.to_f }
      CArray.fuse { a + 1.0 }.to_ca
      print $LOADED_FEATURES.grep(%r{carray/fusion}).empty?
    RUBY
    # From a file, since `fuse` reads its block's source.
    file = Tempfile.new(["evaluator_load", ".rb"])
    file.write(script)
    file.close
    out = IO.popen([RbConfig.ruby, "-Iext", "-Ilib", file.path], &:read)
    file.unlink
    assert_equal "true", out,
                 "materialising an expression should not reach for a plan " \
                 "when nothing asked for one"
  end

  # -- asked -------------------------------------------------------------

  def test_it_is_asked_and_its_answer_is_used
    CArray.expression_evaluator = answering(-1.0)
    assert_equal [-1.0] * BIG, CArray.fuse { @a + @b }.to_ca.to_a
    assert_equal 1, @asked.size
  end

  def test_what_it_is_handed_is_a_plan_for_the_expression
    CArray.expression_evaluator = answering
    CArray.fuse { (@a + @b).sqrt }.to_ca
    plan = @asked.first
    assert_equal %i[add sqrt], plan.nodes.grep(CArray::Fusion::Op).map(&:name)
    assert_equal [@a, @b], plan.leaves
  end

  def test_declining_leaves_the_walk_to_do_it
    CArray.expression_evaluator = declining
    assert_equal (@a + @b).to_a, CArray.fuse { @a + @b }.to_ca.to_a
    assert_equal 1, @asked.size
  end

  def test_to_a_and_copy_ask_as_well
    CArray.expression_evaluator = answering(-1.0)
    assert_equal [-1.0] * BIG, CArray.fuse { @a + @b }.to_a
    assert_equal [-1.0] * BIG, CArray.fuse { @a + @b }.copy.to_a
  end

  # -- when it is not asked ----------------------------------------------

  def test_a_small_array_is_walked_instead
    small = CArray.float64(SMALL) { |i| i.to_f }
    CArray.expression_evaluator = answering
    assert_equal (small + small).to_a, CArray.fuse { small + small }.to_ca.to_a
    assert_empty @asked
  end

  def test_an_array_marked_but_not_operated_on_is_not_handed_over
    CArray.expression_evaluator = answering
    assert_equal @a.to_a, @a.lazy.to_ca.to_a
    assert_empty @asked
  end

  # -- an evaluator that misbehaves ---------------------------------------

  def test_one_that_raises_is_dropped_and_the_walk_answers
    raiser = Object.new
    raiser.define_singleton_method(:call) { |plan, out| raise "boom" }
    CArray.expression_evaluator = raiser
    warned = with_stderr { @result = CArray.fuse { @a + @b }.to_ca }
    assert_match(/evaluator raised/, warned)
    assert_match(/RuntimeError: boom/, warned)
    assert_equal (@a + @b).to_a, @result.to_a
    assert_nil CArray.expression_evaluator
  end

  def test_something_that_cannot_be_called_is_refused
    assert_raise(ArgumentError) { CArray.expression_evaluator = 42 }
    assert_nil CArray.expression_evaluator
  end

  def test_it_can_be_taken_away_again
    CArray.expression_evaluator = answering
    CArray.expression_evaluator = nil
    assert_equal (@a + @b).to_a, CArray.fuse { @a + @b }.to_ca.to_a
    assert_empty @asked
  end

  def with_stderr
    kept, $stderr = $stderr, StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = kept
  end

  # -- storing into an array ----------------------------------------------
  #
  # The saving is in filling the destination directly: making an array and
  # copying it over is most of the work once the expression itself is fast.

  def test_a_store_asks_and_the_answer_lands_in_the_destination
    out = CArray.float64(BIG)
    CArray.expression_evaluator = answering(-1.0)
    out[] = CArray.fuse { @a + @b }
    assert_equal [-1.0] * BIG, out.to_a
    assert_equal 1, @asked.size
  end

  def test_what_the_store_hands_over_is_the_destination_itself
    out = CArray.float64(BIG)
    seen = nil
    evaluator = Object.new
    evaluator.define_singleton_method(:call) { |plan, o| seen = o ; false }
    CArray.expression_evaluator = evaluator
    out[] = CArray.fuse { @a + @b }
    assert_same out, seen
  end

  def test_declining_leaves_the_store_to_the_walk
    out = CArray.float64(BIG)
    CArray.expression_evaluator = declining
    out[] = CArray.fuse { @a + @b }
    assert_equal (@a + @b).to_a, out.to_a
  end

  def test_a_store_of_anything_but_an_expression_is_untouched
    out = CArray.float64(BIG)
    CArray.expression_evaluator = answering(-1.0)
    out[] = @b
    assert_equal @b.to_a, out.to_a
    out[] = 7.0
    assert_equal [7.0] * BIG, out.to_a
    assert_empty @asked
  end

  def test_a_store_that_would_have_to_cast_is_left_to_the_walk
    out = CArray.int32(BIG)
    CArray.expression_evaluator = answering(-1.0)
    out[] = CArray.fuse { @a + @b }
    assert_equal (@a + @b).to_a.map(&:to_i), out.to_a
    assert_empty @asked
  end

  def test_a_store_into_a_different_shape_is_left_to_the_walk
    out = CArray.float64(BIG / 2, 2)
    CArray.expression_evaluator = answering(-1.0)
    out[] = CArray.fuse { @a + @b }
    assert_equal (@a + @b).to_a, out.flatten.to_a
    assert_empty @asked
  end

  def test_a_small_store_is_walked
    small = CArray.float64(SMALL) { |i| i.to_f }
    out = CArray.float64(SMALL)
    CArray.expression_evaluator = answering(-1.0)
    out[] = CArray.fuse { small + small }
    assert_equal (small + small).to_a, out.to_a
    assert_empty @asked
  end

  # -- masks --------------------------------------------------------------

  def test_a_masked_expression_arrives_with_somewhere_to_put_the_mask
    masked = @a.copy
    masked[1] = UNDEF
    got = nil
    evaluator = Object.new
    evaluator.define_singleton_method(:call) do |plan, out|
      got = [plan.masked, out.has_mask?]
      false
    end
    CArray.expression_evaluator = evaluator
    CArray.fuse { masked + @b }.to_ca
    assert_equal [true, true], got
  end
end

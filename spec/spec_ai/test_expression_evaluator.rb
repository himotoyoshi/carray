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

  # The walk leaves the destination masked where the expression is, and an
  # expression with no mask leaves none.
  def test_a_masked_destination_loses_its_mask_to_an_unmasked_expression
    out = CArray.float64(BIG)
    out[0..9] = UNDEF
    CArray.expression_evaluator = answering(-1.0)
    out[] = CArray.fuse { @a + @b }
    assert_equal 1, @asked.size
    assert_equal 0, out.count_masked
  end

  # Cell by cell, a destination that overlaps a leaf would read what it has
  # just written; the walk reads every operand first.
  def test_a_destination_that_overlaps_a_leaf_is_left_to_the_walk
    x = CArray.float64(BIG + 3) { |i| i.to_f }
    y = x[0..-4]
    z = x[3..-1]
    want = (y + y).to_a
    CArray.expression_evaluator = answering(-1.0)
    z[] = CArray.fuse { y + y }
    assert_empty @asked
    assert_equal want, z.to_a
  end

  def test_the_destination_as_a_leaf_read_in_place_is_asked
    out = @a.copy
    CArray.expression_evaluator = answering(-1.0)
    out[] = CArray.fuse { out + @b }
    assert_equal 1, @asked.size
  end

  def test_the_destination_read_shifted_is_left_to_the_walk
    out = @a.copy
    want = (out.shift(1, fill_value: 0.0) + @b).to_a
    CArray.expression_evaluator = answering(-1.0)
    out[] = CArray.fuse { out.shift(1, fill_value: 0.0) + @b }
    assert_empty @asked
    assert_equal want, out.to_a
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

  # -- an expression something else computes whole ---------------------
  #
  # A reduction along an axis, a sort, a scan or a median makes the whole
  # expression before it starts, so the evaluator is asked for it there.  A
  # reduction of the whole array streams the expression in chunks instead,
  # and is left to: asking would make it whole, which is that much more
  # memory.

  def grid (k)
    CArray.float64(200, 100) { |i, j| (i * 100 + j + k) * 0.5 }
  end

  def test_a_reduction_along_an_axis_asks
    g, h = grid(0), grid(1)
    CArray.expression_evaluator = answering(-1.0)
    assert_equal [-100.0] * 200, CArray.fuse { g + h }.sum(axis: 1).to_a
    assert_equal 1, @asked.size
  end

  def test_a_reduction_of_the_whole_array_streams_and_does_not_ask
    CArray.expression_evaluator = answering(-1.0)
    %i[sum mean min max].each do |m|
      assert_equal (@a + @b).send(m), CArray.fuse { @a + @b }.send(m), m
    end
    assert_empty @asked
  end

  def test_a_masked_expression_does_not_stream_and_asks
    masked = @a.copy
    masked[1] = UNDEF
    CArray.expression_evaluator = answering(-1.0)
    assert_equal(-BIG.to_f, CArray.fuse { masked + @b }.sum)
    assert_equal 1, @asked.size
  end

  def test_a_reduction_that_never_streams_asks
    CArray.expression_evaluator = answering(-1.0)
    assert_equal 0.0, CArray.fuse { @a + @b }.variance
    assert_equal 0, CArray.fuse { @a + @b }.min_index
    assert_equal 2, @asked.size
  end

  def test_a_scan_a_sort_and_a_median_ask
    CArray.expression_evaluator = answering(-1.0)
    assert_equal(-BIG.to_f, CArray.fuse { @a + @b }.cumsum[-1])
    assert_equal BIG, CArray.fuse { @a + @b }.sort_index.elements
    assert_equal(-1.0, CArray.fuse { @a + @b }.median)
    assert_equal(-1.0, CArray.fuse { @a + @b }.percentile(50))
    assert_equal 4, @asked.size
  end

  def test_declining_leaves_the_reduction_to_the_walk
    g, h = grid(0), grid(1)
    CArray.expression_evaluator = declining
    assert_equal (g + h).sum(axis: 1).to_a, CArray.fuse { g + h }.sum(axis: 1).to_a
    assert_equal 1, @asked.size
  end

  def test_one_that_raises_inside_a_reduction_is_dropped_and_the_walk_answers
    g, h = grid(0), grid(1)
    raiser = Object.new
    raiser.define_singleton_method(:call) { |plan, out| raise "boom" }
    CArray.expression_evaluator = raiser
    warned = with_stderr { @result = CArray.fuse { g + h }.sum(axis: 1) }
    assert_match(/RuntimeError: boom/, warned)
    assert_equal (g + h).sum(axis: 1).to_a, @result.to_a
    assert_nil CArray.expression_evaluator
  end

  def test_a_small_reduction_is_walked
    small = CArray.float64(10, 10) { |i, j| i + j * 1.0 }
    CArray.expression_evaluator = answering(-1.0)
    assert_equal (small + small).sum(axis: 1).to_a,
                 CArray.fuse { small + small }.sum(axis: 1).to_a
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

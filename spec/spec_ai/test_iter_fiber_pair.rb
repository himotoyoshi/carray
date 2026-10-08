# Two fibers read together.
#
# The FIBER macros cover one source, and one source with an output.
# CA_FOR_EACH_FIBER_PAIR is the third shape: two sources read along the same
# axis at once, which is what a C routine taking two vectors of equal length
# wants.  Nothing inside carray needs it -- the tree's only two-operand walk
# is weighted reduction, and that goes through CA_SLAB_REDUCE_ARRAY_T_EX,
# which does its own stride arithmetic.  A kernel handing the pair to
# someone else's loop cannot: the bytes have to be contiguous before they
# leave.  spec_ai/ext_iter_pair/ is that caller.
#
# The last test pins why the macro exists rather than the raw API: written
# by hand without CA_KERNEL_FIBER_CONTIG, the same walk is correct along the
# last axis and quietly wrong along any other.

require "test/unit"
require "carray"

ext_dir = File.expand_path("ext_iter_pair", __dir__)
$LOAD_PATH.unshift(ext_dir)
begin
  require "iter_pair"
rescue LoadError
  warn "Skipping test_iter_fiber_pair: iter_pair not built."
  warn "Build it with: (cd #{ext_dir} && ruby extconf.rb && make)"
  return
end

class TestIterFiberPair < Test::Unit::TestCase

  def a_base
    CArray.float64(4, 5) { |i, j| Math.sin(i * 1.3 + j * 0.7) }
  end

  def b_base
    CArray.float64(4, 5) { |i, j| Math.cos(i * 0.4 + j * 1.1) }
  end

  # Σ a[i]*b[i] along `axis`, computed without the iterator.
  def reference (a, b, axis)
    (a.copy * b.copy).sum(axis: axis)
  end

  def assert_fibers_agree (a, b, axis, message = nil)
    got = IterPair.dot(a, b, axis)
    ref = reference(a, b, axis)
    assert_equal ref.shape, got.shape, message
    ref.elements.times do |k|
      assert_in_delta ref[k], got[k], 1e-12, "#{message} cell #{k}"
    end
  end

  def test_every_view_kind_along_the_last_axis
    a, b = a_base, b_base
    {
      entity:    [a, b],
      transpose: [a.transpose, b.transpose],
      row_block: [a[1..3, nil], b[1..3, nil]],
      col_block: [a[nil, 1..3], b[nil, 1..3]],
      strided:   [a[nil, [nil, 2]], b[nil, [nil, 2]]],
      lazy:      [a.lazy * 2, b.lazy * 3],
      mixed:     [a.transpose.transpose, b[nil, nil]],
    }.each do |name, (x, y)|
      assert_fibers_agree(x, y, x.ndim - 1, name.to_s)
    end
  end

  def test_every_view_kind_along_axis_zero
    a, b = a_base, b_base
    {
      entity:    [a, b],
      transpose: [a.transpose, b.transpose],
      col_block: [a[nil, 1..3], b[nil, 1..3]],
      strided:   [a[nil, [nil, 2]], b[nil, [nil, 2]]],
      lazy:      [a.lazy * 2, b.lazy * 3],
    }.each do |name, (x, y)|
      assert_fibers_agree(x, y, 0, name.to_s)
    end
  end

  def test_negative_and_middle_axes_of_a_three_dimensional_pair
    a = CArray.float64(2, 3, 4) { |i, j, k| i + j * 0.5 + k * 0.25 }
    b = CArray.float64(2, 3, 4) { |i, j, k| i * 0.3 - j + k }
    (0...3).each { |ax| assert_fibers_agree(a, b, ax, "axis #{ax}") }
  end

  def test_the_two_sources_may_be_the_same_array
    a = a_base
    got = IterPair.dot(a, a, 1)
    ref = (a * a).sum(axis: 1)
    ref.elements.times { |k| assert_in_delta ref[k], got[k], 1e-12 }
  end

  def test_both_mask_cursors_are_yielded
    a, b = a_base, b_base
    am = a.copy
    bm = b.copy
    am[0, 0] = UNDEF          # masked in a only
    bm[0, 1] = UNDEF          # masked in b only
    am[0, 2] = UNDEF          # masked in both
    bm[0, 2] = UNDEF

    got = IterPair.dot_masked(am, bm, 1)
    want = (3...5).sum { |j| a[0, j] * b[0, j] }
    assert_in_delta want, got[0], 1e-12

    # rows the mask does not touch are untouched
    (1...4).each do |i|
      assert_in_delta (0...5).sum { |j| a[i, j] * b[i, j] }, got[i], 1e-12
    end
  end

  def test_an_unmasked_pair_yields_null_mask_cursors
    a, b = a_base, b_base
    assert_equal false, a.has_mask?
    got = IterPair.dot_masked(a, b, 1)
    ref = reference(a, b, 1)
    ref.elements.times { |k| assert_in_delta ref[k], got[k], 1e-12 }
  end

  # Two arrays of different shapes are refused before either walk opens,
  # as for the INOUT forms, even when their element counts and fiber
  # lengths agree.
  def test_shape_disagreement_raises
    a = a_base
    [CArray.float64(4, 6) { 1.0 },
     CArray.float64(20) { 1.0 },
     CArray.float64(5, 4) { 1.0 }].each do |b|
      e = assert_raise(ArgumentError) { IterPair.dot(a, b, 0) }
      assert_match(/differ in shape/, e.message)
    end
    # Same rank, element count and fiber length; different shape.
    assert_raise(ArgumentError) {
      IterPair.dot(CArray.float64(2, 3, 4).seq, CArray.float64(4, 3, 2).seq, 1)
    }
  end

  # Why the macro rather than the raw API: the flag it adds is easy to leave
  # out, and leaving it out is correct exactly where an author looks first.
  def test_the_raw_walk_without_the_contig_flag_agrees_on_the_last_axis
    a, b = a_base, b_base
    macro = IterPair.dot(a, b, 1)
    raw   = IterPair.dot_raw(a, b, 1)
    macro.elements.times { |k| assert_in_delta macro[k], raw[k], 1e-12 }
  end

  def test_the_raw_walk_without_the_contig_flag_is_wrong_on_axis_zero
    a, b = a_base, b_base
    macro = IterPair.dot(a, b, 0)
    raw   = IterPair.dot_raw(a, b, 0)
    ref   = reference(a, b, 0)
    ref.elements.times { |k| assert_in_delta ref[k], macro[k], 1e-12 }
    assert_equal true,
                 (0...ref.elements).any? { |k| (ref[k] - raw[k]).abs > 1e-9 },
                 "the raw walk was expected to differ here"
  end

  # The second walk is opened paired with the first, so when it raises
  # partway, the first is closed too: a contiguous view as the first source
  # is not left attached.  A shape refusal comes before either walk opens.
  def test_a_refused_or_raising_second_source_closes_the_first
    omit "development build only" unless CArray.respond_to?(:__attached_views__)
    e = CArray.float64(8, 6).seq!
    o = CArray.object(4, 6) { 1.0 }
    o[3, 5] = Object.new
    raising = CArray.wrap_readonly(o, CA_FLOAT64)
    [[e[1..4, nil], CArray.float64(6).seq!, 1],   # refused: shapes differ
     [e[2..5, nil], raising, 1],                   # raises in a later fiber
     [e[2..5, nil], raising, 0]].each do |a, b, axis|
      before = CArray.__attached_views__
      assert_raise(ArgumentError, RuntimeError, TypeError) { IterPair.dot(a, b, axis) }
      assert_equal before, CArray.__attached_views__
      assert_equal false, a.attached?
    end
  end

end

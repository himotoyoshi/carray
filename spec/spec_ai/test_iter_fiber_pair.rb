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

  def test_shape_disagreement_skips_the_body
    a = a_base
    b = CArray.float64(4, 6) { 1.0 }
    got = IterPair.dot(a, b, 1)
    assert_equal 0, got.instance_variable_get(:@fibers)
  end

  def test_rank_disagreement_skips_the_body
    a = a_base
    b = CArray.float64(20) { 1.0 }
    got = IterPair.dot(a, b, 0)
    assert_equal 0, got.instance_variable_get(:@fibers)
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
end

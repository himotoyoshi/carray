# A CA_OBJECT cell is a VALUE, and a lazy materialise writes those cells
# into a buffer no Ruby object owns yet -- the copy's destination, a lazy
# view's own attach buffer, or an arena scratch.  Object-lane kernels call
# rb_funcall per cell, so a collection halfway through used to free what
# had been written so far: wrong values at a few thousand elements, and a
# crash once a freed slot was reused.
#
# Pinned here:
#   1. a plain lazy binop over a CA_OBJECT array agrees with the eager
#      result at sizes large enough to provoke a collection,
#   2. repeated materialise in one process stays correct (the shape that
#      used to segfault),
#   3. GC.stress makes the failure deterministic, so the small-size cases
#      below stand in for the flaky large-size ones,
#   4. the same holds for a lazy right operand, a monop, a triop, a
#      comparison, a chain, a partial materialise, and a reduction over a
#      lazy source.

$LOAD_PATH.unshift File.expand_path("../../ext", __dir__)
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "carray"
require "test/unit"

class TestLazyObjectGC < Test::Unit::TestCase

  # Rational allocates a fresh object per cell, so every kernel step
  # produces a VALUE that exists nowhere but the destination buffer.
  def obj (n, num = 1)
    CArray.object(n) { |i| Rational(i * num + 1, 3) }
  end

  # Runs the block with GC.stress on, restoring it even on failure.
  def under_gc_stress
    was = GC.stress
    GC.stress = true
    begin
      yield
    ensure
      GC.stress = was
    end
  end

  def test_lazy_binop_matches_eager_at_size
    [1000, 4000, 20000].each do |n|
      o = obj(n)
      assert_equal (o + 1).to_a, (o.lazy + 1).to_ca.to_a, "n=#{n}"
    end
  end

  def test_repeated_materialise_stays_correct
    o = obj(1000)
    expected = (o + 1).to_a
    20.times do |k|
      assert_equal expected, (o.lazy + 1).to_ca.to_a, "iteration #{k}"
    end
  end

  def test_lazy_binop_under_gc_stress
    o = obj(20)
    expected = (o + 1).to_a
    under_gc_stress { assert_equal expected, (o.lazy + 1).to_ca.to_a }
  end

  def test_lazy_right_operand_under_gc_stress
    o = obj(20)
    b = obj(20, 2)
    expected = (o + b).to_a
    under_gc_stress { assert_equal expected, (o.lazy + (b.lazy * 1)).to_ca.to_a }
  end

  def test_eager_binop_with_lazy_operand_under_gc_stress
    o = obj(20)
    b = obj(20, 2)
    expected = (o + b).to_a
    under_gc_stress { assert_equal expected, (o + (b.lazy * 1)).to_a }
  end

  def test_lazy_monop_under_gc_stress
    o = obj(20)
    expected = (-o).to_a
    under_gc_stress { assert_equal expected, (-o.lazy).to_ca.to_a }
  end

  # clip is the three-operand lazy view; CArray.fuse would exercise the
  # same materialise but spends its time parsing the block source, which
  # GC.stress makes far slower than the thing under test.
  def test_lazy_triop_under_gc_stress
    o = obj(20)
    lo, hi = Rational(1, 3), Rational(4, 3)
    expected = (o + 1).clip(lo, hi).to_a
    under_gc_stress do
      assert_equal expected, (o.lazy + 1).clip(lo, hi).to_ca.to_a
    end
  end

  # The comparison result is boolean, so its own destination holds no
  # VALUEs -- what needs guarding is the operand scratch each side is
  # pulled into, which only holds fresh objects when the operand is
  # itself lazy.
  def test_lazy_comparison_under_gc_stress
    o = obj(20)
    b = obj(20, 2)
    expected = ((o + 1) > (b + 0)).to_a
    under_gc_stress do
      assert_equal expected, ((o.lazy + 1) > (b.lazy + 0)).to_ca.to_a
    end
  end

  def test_lazy_scalar_comparison_under_gc_stress
    o = obj(20)
    q = Rational(4, 3)
    expected = (o + 1).eq(q).to_a
    under_gc_stress { assert_equal expected, (o.lazy + 1).eq(q).to_ca.to_a }
  end

  def test_lazy_chain_under_gc_stress
    o = obj(20)
    expected = ((o + 1) * 2 - 1).to_a
    under_gc_stress { assert_equal expected, ((o.lazy + 1) * 2 - 1).to_ca.to_a }
  end

  def test_partial_materialise_under_gc_stress
    o = obj(20)
    expected = (o + 1).to_a[0, 10]
    under_gc_stress { assert_equal expected, (o.lazy + 1)[0..9].to_ca.to_a }
  end

  def test_reduction_over_lazy_source_under_gc_stress
    o = obj(20)
    expected = (o + 1).to_a.inject(:+)
    under_gc_stress { assert_equal expected, (o.lazy + 1).sum }
  end

end

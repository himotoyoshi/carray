# all / any / none stop walking once the answer is settled.  The answers
# must not depend on where the deciding cell sits relative to the blocks
# the walk is cut into, on masked cells in front of it, or on the view.

require "test/unit"
require "carray"

class TestBooleanFoldSettle < Test::Unit::TestCase

  N = 3 * 16384 + 5

  def reference (a, kind)
    vals = a.to_a.flatten.zip(a.is_masked.to_a.flatten).reject { |_, m| m }.map(&:first)
    case kind
    when :any  then vals.any?
    when :all  then vals.all?
    when :none then vals.none?
    end
  end

  def positions
    [0, 1, 4095, 4096, 16383, 16384, 16385, 2 * 16384, N - 1]
  end

  def test_one_deciding_cell_at_block_boundaries
    positions.each do |pos|
      t = CArray.boolean(N) { false }
      t[pos] = true
      f = t.not
      assert_equal true,  t.any,  "any, true at #{pos}"
      assert_equal false, t.none, "none, true at #{pos}"
      assert_equal false, f.all,  "all, false at #{pos}"
    end
    assert_equal false, CArray.boolean(N) { false }.any
    assert_equal true,  CArray.boolean(N) { true }.all
    assert_equal true,  CArray.boolean(N) { false }.none
  end

  def test_masked_deciding_cells_do_not_settle
    positions.each do |pos|
      a = CArray.boolean(N) { false }
      a[0..pos] = true
      a[0..pos] = UNDEF
      assert_equal false, a.any,  "any, masked trues up to #{pos}"
      assert_equal true,  a.none, "none, masked trues up to #{pos}"
      b = a.not
      assert_equal true,  b.all,  "all, masked falses up to #{pos}"
      a[N - 1] = true
      assert_equal true,  a.any,  "any, last cell true behind masked trues up to #{pos}"
    end
  end

  def test_views_and_axes_match_the_reference
    r = Random.new(7)
    base = CArray.boolean(64, 3000) { |i| r.rand < 0.0005 }
    base[r.rand(64), r.rand(3000)] = UNDEF
    views = [base, base[nil, 1..-1], base[1..-2, nil].transpose, base[nil, CA_INT64([0, 5, 2999])], base.flip(1)]
    views.each do |v|
      %i[any all none].each do |kind|
        x = (kind == :all) ? v.not : v
        assert_equal reference(x, kind), x.send(kind), "#{kind} on #{v.class}"
        (0...v.ndim).each do |ax|
          got = x.send(kind, axis: ax)
          n0 = v.shape[1 - ax]
          n0.times do |j|
            fib = ax == 0 ? x[nil, j] : x[j, nil]
            assert_equal reference(fib, kind), got[j], "#{kind}(axis: #{ax}) fiber #{j} on #{v.class}"
          end
        end
      end
    end
  end

def test_unmasked_leading_axes_match_the_reference
  r = Random.new(11)
  [[2048, 300], [3, 700, 90], [5, 4, 1200]].each do |shape|
    t = CArray.boolean(*shape) { false }
    20.times { t[*shape.map { |n| r.rand(n) }] = true }
    f = t.not
    (0...t.ndim - 1).each do |ax|
      got_any, got_none, got_all = t.any(axis: ax), t.none(axis: ax), f.all(axis: ax)
      moved = (0...t.ndim).to_a - [ax] + [ax]
      flat = t.transpose(*moved).copy.reshape(got_any.elements, shape[ax]).to_a
      flat.each_with_index do |fiber, i|
        assert_equal fiber.any?,             got_any[i],  "any(axis: #{ax}) on #{shape}, fiber #{i}"
        assert_equal fiber.none?,            got_none[i], "none(axis: #{ax}) on #{shape}, fiber #{i}"
        assert_equal fiber.none?,            got_all[i],  "all(axis: #{ax}) of the negation on #{shape}, fiber #{i}"
      end
    end
  end
end

end

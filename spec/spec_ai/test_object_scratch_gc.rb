# Object cells that a view computes (a CAObject, a lazy expression) live
# only in buffers no Ruby object owns while a kernel calls Ruby for each
# cell.  These run under GC.stress, where an unheld cell is collected at
# the first allocation.

require 'test/unit'
require 'carray'

class TestObjectScratchGC < Test::Unit::TestCase

  class Thirds < CAObject
    def initialize (n, m)
      super(CA_OBJECT, [n, m], read_only: true)
      @m = m
    end

    private

    def fetch_index (idx)
      Rational(idx[0] * @m + idx[1] + 1, 3)
    end
  end

  def thirds
    CA_OBJECT(Array.new(12) { |i| Rational(i + 1, 3) }).reshape(3, 4).copy
  end

  def under_stress
    GC.stress = true
    yield
  ensure
    GC.stress = false
  end

  def assert_same_under_stress (view)
    want = yield(view.copy)
    got  = under_stress { yield(view) }
    assert_equal(want, got)
  end

  # ---- the kernel iterator's scratch ----

  def test_reductions_over_a_computing_view
    [Thirds.new(3, 4), Thirds.new(3, 4).transpose,
     thirds.lazy + 1, (thirds.lazy + 1)[0..1, nil]].each do |v|
      assert_same_under_stress(v) { |x| x.sum(axis: 1).to_a }
      assert_same_under_stress(v) { |x| x.cumsum(axis: 1).to_a }
      assert_same_under_stress(v) { |x| x.sort_index(axis: 1).to_a }
    end
  end

  # ---- the tables of unique and its family ----

  def test_unique_over_a_computing_view
    [Thirds.new(3, 4), Thirds.new(3, 4)[1..2, nil], thirds.lazy + 1].each do |v|
      assert_same_under_stress(v) { |x| x.unique.to_a }
      assert_same_under_stress(v) { |x| x.value_counts.to_a }
    end
  end

end

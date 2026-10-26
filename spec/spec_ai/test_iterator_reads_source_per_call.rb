# A window or block iterator reads its source when it is called: a change to
# the source made after an earlier call shows in the next one.  What the
# iterator built from the source's values or mask is kept for one call only,
# so two calls never mix what the source held at two times.

require "test/unit"
require "carray"

class TestIteratorReadsSourcePerCall < Test::Unit::TestCase

  def masked_line
    a = CArray.float64(12).seq!
    a[2] = UNDEF
    a
  end

  def answer (it, op)
    v = op.(it)
    v.respond_to?(:to_a) ? v.to_a : v
  end

  WINDOW_OPS = {
    sum:    ->(it) { it.sum },
    mean:   ->(it) { it.mean },
    max:    ->(it) { it.max },
    median: ->(it) { it.median },
    sum_mc: ->(it) { it.sum(min_count: 3) },
  }

  CHANGES = {
    unmask:    ->(a) { a[2] = 2.0 },
    mask_more: ->(a) { a[5] = UNDEF; a[6] = UNDEF },
    values:    ->(a) { a[] = a - 1000 },
  }

  def test_window_answers_from_the_source_as_it_is
    [:truncate, :skip, :nearest].each do |bounds|
      WINDOW_OPS.each do |first, f|
        WINDOW_OPS.each do |second, s|
          CHANGES.each do |change, c|
            a = masked_line
            it = a.windows(-1..1, bounds: bounds)
            f.(it)
            c.(a)
            assert_equal answer(a.windows(-1..1, bounds: bounds), s),
                         answer(it, s),
                         "#{bounds} #{first} then #{change} then #{second}"
          end
        end
      end
    end
  end

  # The mean once divided the new sum by the count of cells present before.
  def test_window_mean_after_a_masked_cell_is_filled
    a = masked_line
    it = a.windows(-1..1, bounds: :truncate)
    it.sum
    a[2] = 2.0
    assert_equal (1..10).map(&:to_f), it.mean.to_a
  end

  def test_window_sliding_view_follows_the_source
    a = CArray.int32(4, 6).seq!
    it = a.windows(-1..1, -1..1, bounds: :nearest)
    it.sliding_view
    a[0, 0] = 100
    assert_equal 100, it.sliding_view[0, 0, 1, 1]
  end

  BLOCK_OPS = {
    sum:  ->(it) { it.sum },
    max:  ->(it) { it.max },
    each: ->(it) { acc = []; it.each { |t| acc << t.sum }; acc },
    map:  ->(it) { it.map { |t| t } },
  }

  def test_block_answers_from_the_source_as_it_is
    [[4, 6], [5, 7]].each do |shape|
      BLOCK_OPS.each do |first, f|
        BLOCK_OPS.each do |second, s|
          a = CArray.float64(*shape).seq!
          a[0, 0] = UNDEF
          it = a.blocks(2, 3)
          f.(it)
          a[0, 0] = 0.5
          a[1, 1] = UNDEF
          assert_equal answer(a.blocks(2, 3), s), answer(it, s),
                       "#{shape} #{first} then #{second}"
        end
      end
    end
  end
end

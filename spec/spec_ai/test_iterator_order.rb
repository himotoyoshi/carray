require "test/unit"
require "carray"

# An iterator member whose pieces do not overlap ranks each cell among the
# cells of its piece, as CArray#order ranks the piece alone; the window
# iterator refuses. The members are collected, so a new member without a
# builder below fails.

class TestIteratorOrder < Test::Unit::TestCase

  L  = 5
  P  = 3
  KEYWORDS = [{}, { method: :dense }, { descending: true },
              { method: :dense, descending: true }, { kind: :stable }].freeze
  # Ties, NaN and -0.0 against 0.0 are where an order can slip.
  ROWS = [[3.0, 1.0, 3.0, 2.0, 1.0],
          [Float::NAN, -0.0, 0.0, 5.0, Float::NAN],
          [9.0, 9.0, 9.0, 9.0, 9.0]].freeze

  def self.iterator_classes
    Object.constants.grep(/Iterator\z/).each { |c| Object.const_get(c) }
    ObjectSpace.each_object(Class).select { |c| c < CAIterator }
  end

  def labels = CArray.object(P * L) { |i| "k#{i / L}" }.categorize(labels: (0...P).map { |i| "k#{i}" })

  def builders
    {
      CASlabIterator        => ->(d) { d[nil, :>] },
      CABlockIterator       => ->(d) { d.flatten.copy.blocks(L) },
      CAWindowIterator      => nil,
      CASegmentIterator     => ->(d) { d.flatten.copy.segments(lengths: [L] * P) },
      CACategoricalIterator => ->(d) { d.flatten.copy.group_by_category(labels) },
      CAGroupIterator       => ->(d) { d.flatten.copy[labels] },
    }
  end

  def call (it, kw)
    it.is_a?(CAGroupIterator) ? it.order(axis: :group, **kw) : it.order(**kw)
  end

  def data (type)
    d = CArray.float64(P, L) { |i, j| ROWS[i][j] }
    d = case type
        when :float64 then d
        when :int32   then CArray.int32(P, L) { |i, j| [[3, 1, 3, 2, 1], [4, 0, 0, 5, 4], [9] * 5][i][j] }
        when :object  then CArray.object(P, L) { |i, j| [[3, 1, 3, 2, 1], [4.5, 0, 0, 5, 4], [9] * 5][i][j] }
        when :time    then CArray.int64(P, L) { |i, j| [[3, 1, 3, 2, 1], [4, 0, 0, 5, 4], [9] * 5][i][j] }.time(unit: :D)
        end
    d[0, 4] = UNDEF
    d[2, 1] = UNDEF
    d
  end

  def test_every_member_builds
    assert_equal [], self.class.iterator_classes - builders.keys
  end

  %i[float64 int32 object time].each do |type|
    define_method("test_each_piece_ranks_as_the_core_#{type}") do
      d = data(type)
      diffs = []
      builders.each do |klass, build|
        next unless build
        KEYWORDS.each do |kw|
          got = call(build.(d), kw)
          assert_equal CA_INT64, got.data_type, "#{klass} #{kw}"
          got = got.reshape(P, L)
          (0...P).each do |i|
            want = d[i, nil].copy.order(**kw).to_a
            have = got[i, nil].to_a
            diffs << "#{klass} order(#{kw}) row #{i}: #{have.inspect} != #{want.inspect}" unless have == want
          end
        end
      end
      assert_equal [], diffs
    end
  end

  # A member refuses what CArray#order refuses.
  def test_keywords
    d = data(:float64)
    builders.each do |klass, build|
      next unless build
      assert_raise(ArgumentError, "#{klass}") { call(build.(d), method: :average) }
      assert_raise(TypeError, "#{klass}") { call(build.(d), method: "dense") }
      assert_raise(ArgumentError, "#{klass}") { call(build.(d), kind: :merge) }
    end
  end

  def test_window_refuses
    assert_raise(NotImplementedError) { CA_INT32([1, 2, 3]).windows(-1..1).order }
  end

  def test_block_partial_tile
    a = CArray.int32(3, 5) { |i, j| [[5, 4, 3, 2, 1], [0, 9, 8, 7, 6], [1, 1, 2, 2, 0]][i][j] }
    ranked = a.blocks(2, 2).order
    assert_equal [0, 1], ranked[0..1, 4].to_a      # the 2x1 edge tile holds 1 and 6
    assert_equal [0, 1, 0, 1, 0], ranked[2, nil].to_a   # the 1x2 tiles and the 1x1
  end

  # The rank never counts a cell of the segment before, nor one outside
  # every segment.
  def test_segment_random
    rng = Random.new(7)
    300.times do
      n = rng.rand(0..12)
      v = CArray.float64(n) { [1.0, 2.0, Float::NAN, -0.0, 0.0, 3.0][rng.rand(6)] }
      n.times { |i| v[i] = UNDEF if rng.rand < 0.25 }
      cuts = Array.new(rng.rand(1..5)) { rng.rand(0..n) }.sort
      KEYWORDS.each do |kw|
        got = v.segments(offsets: cuts).order(**kw).to_a
        want = Array.new(n, UNDEF)
        (cuts.size - 1).times do |c|
          lo, hi = cuts[c], cuts[c + 1]
          want[lo...hi] = v[lo...hi].order(**kw).to_a if hi > lo
        end
        assert_equal want, got, "#{v.to_a.inspect} #{cuts.inspect} #{kw}"
      end
    end
  end

  def test_categorical_skips_unclassified_cells
    codes = CA_INT32([0, 0, 0, 1])
    codes[1] = UNDEF
    it = CA_FLOAT64([3, 2, 1, 4]).group_by_category(codes.categorize)
    assert_equal [1, UNDEF, 0, 0], it.order.to_a
  end

  def test_categorical_axis_form
    h = CArray.float64(2, 4) { |i, j| [[3, 1, 2, 0], [5, 9, 4, 1]][i][j] }
    it = h.group_by_category(CA_INT32([0, 1, 0, 1]).categorize)
    assert_equal [[1, 1, 0, 0], [1, 1, 0, 0]], it.order(axis: 1).to_a
  end

  def test_axis_group_band
    s = CArray.float64(2, 4) { |i, j| [[3, 1, 2, 0], [5, 9, 4, 1]][i][j] }
    season = CA_INT32([0, 1, 0, 1]).categorize
    assert_equal [[1, 1, 0, 0], [1, 1, 0, 0]], s[nil, season].order(axis: :group).to_a
    assert_raise(ArgumentError) { s[nil, season].order(axis: [:group, 0]) }
  end
end

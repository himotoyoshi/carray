require "test/unit"
require "carray"

# CArray#lag is the value n steps earlier along an axis, UNDEF where there is
# none. An iterator member whose pieces do not overlap gives each piece its
# own lag, so a lag never reaches into another piece; the window iterator
# refuses. The members are collected, so a new member without a builder
# below fails.

class TestLag < Test::Unit::TestCase

  L  = 4
  P  = 3
  NS = [0, 1, 2, -1, L, -(L + 1)].freeze

  def test_core
    x = CA_FLOAT64([1.0, 4.0, 9.0])
    assert_equal [UNDEF, 1.0, 4.0], x.lag.to_a
    assert_equal [UNDEF, 3.0, 5.0], (x - x.lag).to_a
    assert_equal [4.0, 9.0, UNDEF], x.lag(-1).to_a
    assert_equal [1.0, 4.0, 9.0], x.lag(0).to_a
    assert_equal [UNDEF] * 3, x.lag(5).to_a
  end

  # The cell n steps back is taken by position, masked or not.
  def test_masked_cell_behind
    x = CA_INT32([1, 2, 3])
    x[1] = UNDEF
    assert_equal [UNDEF, 1, UNDEF], x.lag.to_a
  end

  def test_axis
    m = CArray.int32(2, 3).seq!
    assert_equal [[UNDEF, 0, 1], [UNDEF, 3, 4]], m.lag(axis: 1).to_a
    assert_equal [[UNDEF] * 3, [0, 1, 2]], m.lag(axis: -2).to_a
    # a lag runs along one axis, which an array of more dimensions must name
    assert_raise(ArgumentError) { m.lag }
    assert_raise(TypeError) { m.lag(axis: [0, 1]) }
    assert_raise(ArgumentError) { m.lag(axis: 2) }
    assert_raise(TypeError) { m.lag(1.5) }
  end

  # A lag is shift with UNDEF as the fill value, a view of the source.
  def test_view
    x = CA_INT32([1, 2, 3])
    x[2] = 9
    assert_equal [UNDEF, 1, 2], x.lag.to_a
    x.lag[2] = 7
    assert_equal [1, 7, 9], x.to_a
  end

  def test_time
    t = CArray.time(%w[2024-01-01 2024-01-02 2024-01-03], unit: :D)
    lagged = t.lag
    assert_kind_of CATime, lagged
    assert_equal UNDEF, lagged[0]
    assert_equal "2024-01-02", lagged[2].to_s
  end

  def self.iterator_classes
    Object.constants.grep(/Iterator\z/).each { |c| Object.const_get(c) }
    ObjectSpace.each_object(Class).select { |c| c < CAIterator }
  end

  def labels = CArray.object(P * L) { |i| "k#{i / L}" }.categorize(labels: (0...P).map { |i| "k#{i}" })

  # Each builds an iterator over the pieces (row i of d is piece i); nil for
  # a member whose pieces overlap.
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

  def call (it, n)
    it.is_a?(CAGroupIterator) ? it.lag(n, axis: :group) : it.lag(n)
  end

  def data (type)
    d = CArray.int32(P, L) { |i, j| [[3, 1, 3, 2], [5, 5, 6, 7], [8, 9, 4, 4]][i][j] }
    d = case type
        when :float64 then d.float64
        when :int32   then d
        when :object  then d.object
        when :time    then d.int64.time(unit: :D)
        end
    d[0, 1] = UNDEF
    d[2, 3] = UNDEF
    d
  end

  def plain (row)
    row.map { |x| x.is_a?(CATime::Element) ? x.to_s : x }
  end

  def test_every_member_builds
    assert_equal [], self.class.iterator_classes - builders.keys
  end

  %i[float64 int32 object time].each do |type|
    define_method("test_each_piece_lags_as_the_core_#{type}") do
      d = data(type)
      diffs = []
      builders.each do |klass, build|
        next unless build
        NS.each do |n|
          got = call(build.(d), n).reshape(P, L)
          (0...P).each do |i|
            want = plain(d[i, nil].copy.lag(n).to_a)
            have = plain(got[i, nil].to_a)
            diffs << "#{klass} lag(#{n}) row #{i}: #{have.inspect} != #{want.inspect}" unless have == want
          end
        end
      end
      assert_equal [], diffs
    end
  end

  def test_window_refuses
    assert_raise(NotImplementedError) { CA_INT32([1, 2, 3]).windows(-1..1).lag }
  end

  # A partial edge tile counts only the cells it has, not the padding that
  # completes it.
  def test_block_partial_tile
    a = CArray.int32(3, 5).seq!
    lagged = a.blocks(2, 2).lag
    assert_equal [UNDEF, 4], lagged[0..1, 4].to_a      # the 2x1 edge tile
    assert_equal [UNDEF, 10, UNDEF, 12, UNDEF], lagged[2, nil].to_a
    assert_equal [5, 6, 7, 8, UNDEF], a.blocks(2, 2).lag(-2)[0, nil].to_a
  end

  # A lag never reaches across into the segment before, nor out of the
  # cells the segments cover.
  def test_segment_random
    rng = Random.new(5)
    300.times do
      n = rng.rand(0..12)
      v = CArray.float64(n) { rng.rand(0..9).to_f }
      n.times { |i| v[i] = UNDEF if rng.rand < 0.2 }
      cuts = Array.new(rng.rand(1..5)) { rng.rand(0..n) }.sort
      steps = rng.rand(-3..3)
      got = v.segments(offsets: cuts).lag(steps).to_a
      want = Array.new(n, UNDEF)
      (cuts.size - 1).times do |c|
        lo, hi = cuts[c], cuts[c + 1]
        next if hi == lo
        want[lo...hi] = v[lo...hi].lag(steps).to_a
      end
      assert_equal want, got, "#{v.to_a.inspect} #{cuts.inspect} lag(#{steps})"
    end
  end

  def test_categorical_skips_unclassified_cells
    codes = CA_INT32([0, 0, 0, 1])
    codes[1] = UNDEF
    it = CA_FLOAT64([1, 2, 3, 4]).group_by_category(codes.categorize)
    assert_equal [UNDEF, UNDEF, 1.0, UNDEF], it.lag.to_a
  end

  def test_categorical_axis_form
    h = CArray.float64(2, 4).seq!
    it = h.group_by_category(CA_INT32([0, 1, 0, 1]).categorize)
    assert_equal [[UNDEF, UNDEF, 0.0, 1.0], [UNDEF, UNDEF, 4.0, 5.0]], it.lag(axis: 1).to_a
  end

  def test_axis_group_band
    s = CArray.float64(2, 4).seq!
    season = CA_INT32([0, 1, 0, 1]).categorize
    assert_equal [[UNDEF, UNDEF, 0.0, 1.0], [UNDEF, UNDEF, 4.0, 5.0]],
                 s[nil, season].lag(axis: :group).to_a
    assert_raise(ArgumentError) { s[nil, season].lag(axis: [:group, 0]) }
  end
end

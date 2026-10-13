require "test/unit"
require "carray"

# first / last / nunique are on the required surface of every iterator
# member, and each member answers a piece as the core answers that piece
# alone. The members are collected, so a new member without a builder below
# fails.

class TestIteratorFirstLastNunique < Test::Unit::TestCase

  L   = 4
  OPS = %i[first last nunique].freeze
  # Each row is one piece; the masked cells are left out of every answer.
  ROWS = [
    [nil, nil, nil, nil],          # no present cell
    [nil, 2.0, nil, nil],          # one
    [3.0, nil, 3.0, 1.0],          # a repeat
    [Float::NAN, -0.0, 0.0, Float::NAN],   # NaN is one value, -0.0 is 0.0
    [5.0, 6.0, 7.0, 8.0],
  ].freeze
  P = ROWS.size

  def self.iterator_classes
    Object.constants.grep(/Iterator\z/).each { |c| Object.const_get(c) }
    ObjectSpace.each_object(Class).select { |c| c < CAIterator }
  end

  def labels = CArray.object(P * L) { |i| "k#{i / L}" }.categorize(labels: (0...P).map { |i| "k#{i}" })

  # Each builds the iterator over the pieces (row i of d is piece i) and
  # reads one result per piece.
  def builders
    per_row = ->(r) { r }
    {
      CASlabIterator        => [->(d) { d[nil, :>] }, per_row],
      CABlockIterator       => [->(d) { d.flatten.copy.blocks(L) }, per_row],
      CAWindowIterator      => [->(d) { d.flatten.copy.windows(0..L - 1, bounds: :truncate) },
                                ->(r) { (0...P).map { |i| r[i * L] } }],
      CASegmentIterator     => [->(d) { d.flatten.copy.segments(lengths: [L] * P) }, per_row],
      CACategoricalIterator => [->(d) { d.flatten.copy.group_by_category(labels) }, per_row],
      CAGroupIterator       => [->(d) { d.flatten.copy[labels] }, per_row],
    }
  end

  def call (it, op, **kw)
    kw = kw.merge(axis: :group) if it.is_a?(CAGroupIterator)
    it.public_send(op, **kw)
  end

  def data (type)
    d = CArray.object(P, L) { |i, j| ROWS[i][j] || 0.0 }
    d = case type
        when :float64 then d.float64
        when :int32   then d.float64.pmax(-1.0).pmin(9.0).to_type(:int32)  # NaN is not an int
        when :object  then d
        when :time    then d.float64.pmax(0.0).pmin(9.0).to_type(:int64).time(unit: :D)
        end
    if type == :int32 || type == :time
      # the NaN row has no counterpart in these types; give it repeats instead
      (0...L).each { |j| d[3, j] = [1, 2, 2, 1][j] } if type == :int32
      (0...L).each { |j| d[3, j] = CArray.time("1970-01-0#{[2, 3, 3, 2][j]}", unit: :D)[0] } if type == :time
    end
    ROWS.each_with_index { |row, i| row.each_with_index { |v, j| d[i, j] = UNDEF if v.nil? } }
    d
  end

  def plain (x)
    x.respond_to?(:to_time) && x.is_a?(CATime::Element) ? x.to_time : x
  end

  def same (a, b)
    return a.equal?(b) if a.equal?(UNDEF) || b.equal?(UNDEF)
    a, b = plain(a), plain(b)
    return (a.nan? && b.nan?) || a.eql?(b) if a.is_a?(Float) && b.is_a?(Float)
    a == b
  end

  def test_every_member_builds
    assert_equal [], self.class.iterator_classes - builders.keys
  end

  %i[float64 int32 object time].each do |type|
    define_method("test_each_piece_answers_as_the_core_#{type}") do
      d = data(type)
      diffs = []
      builders.each do |klass, (build, per_piece)|
        OPS.each do |op|
          got = per_piece.(call(build.(d), op).to_a)
          (0...P).each do |i|
            want = d[i, nil].copy.public_send(op)
            diffs << "#{klass} #{op} row #{i}: #{got[i].inspect} != #{want.inspect}" unless same(got[i], want)
          end
        end
      end
      assert_equal [], diffs
    end
  end

  # The answer keeps the data type of the core's: a time comes back a time,
  # a count int64.
  def test_answer_types
    d = data(:time)
    builders.each do |klass, (build, _)|
      assert_kind_of CATime, call(build.(d), :first), "#{klass} first"
      assert_kind_of CATime, call(build.(d), :last),  "#{klass} last"
      assert_equal CA_INT64, call(build.(d), :nunique).data_type, "#{klass} nunique"
    end
  end

  # The core ones take neither min_count: nor fill_value:, so neither does a
  # member.
  def test_refuses_min_count
    d = data(:float64)
    builders.each do |klass, (build, _)|
      OPS.each do |op|
        assert_raise(ArgumentError, "#{klass} #{op}") { call(build.(d), op, min_count: 1) }
      end
    end
  end

  # The per-fiber form of a categorical: case A (classified along the axis)
  # and a full-shape classifier.
  def test_categorical_axis_form
    h = CArray.float64(3, 4).seq!
    h[0, 0] = UNDEF
    h[2, 1] = UNDEF
    along = h.group_by_category(CA_INT32([0, 1, 0, 1]).categorize)
    assert_equal [[2.0, 4.0, 8.0], [1.0, 5.0, 11.0]], along.first(axis: 1).to_a
    assert_equal [[2.0, 6.0, 10.0], [3.0, 7.0, 11.0]], along.last(axis: 1).to_a
    assert_equal [[1, 2, 2], [2, 2, 1]], along.nunique(axis: 1).to_a
    rows = h.group_by_category(CArray.int32(3, 4) { |i| i % 3 }.categorize)
    assert_equal [[1.0, UNDEF, UNDEF], [UNDEF, 4.0, UNDEF], [UNDEF, UNDEF, 8.0]],
                 rows.first(axis: 1).to_a
    assert_equal [[3, 0, 0], [0, 4, 0], [0, 0, 3]], rows.nunique(axis: 1).to_a
  end

  # An axis group keeps its band axes, and cannot fold one into a group.
  def test_axis_group_band
    s = CArray.float64(2, 3, 4).seq!
    s[1, 0, 0] = UNDEF
    season = CA_INT32([0, 1, 0, 1]).categorize
    first = s[nil, nil, season].first(axis: :group)
    assert_equal [2, 3, 2], first.shape
    assert_equal [14.0, 13.0], first[1, 0, nil].to_a
    assert_equal [1, 2], s[nil, nil, season].nunique(axis: :group)[1, 0, nil].to_a
    assert_raise(NotImplementedError) { s[nil, nil, season].first(axis: [:group, 0]) }
  end

  # A segment iterator finds every segment's first and last present cell at
  # once; empty segments and segments at the ends are where that can slip.
  def test_segment_edges_random
    rng = Random.new(3)
    300.times do
      n = rng.rand(0..12)
      v = CArray.float64(n) { [1.0, 2.0, Float::NAN, -0.0, 0.0, 3.0][rng.rand(6)] }
      n.times { |i| v[i] = UNDEF if rng.rand < 0.3 }
      cuts = Array.new(rng.rand(1..5)) { rng.rand(0..n) }.sort
      it = v.segments(offsets: cuts)
      OPS.each do |op|
        got = it.public_send(op).to_a
        want = it.each.map { |piece| piece.public_send(op) }
        assert got.zip(want).all? { |a, b| same(a, b) },
               "#{op} #{v.to_a.inspect} #{cuts.inspect}: #{got.inspect} != #{want.inspect}"
      end
    end
  end

  # A frame's group reduction reaches the iterator, so a group's first and
  # last come back in the column's own type.
  def test_frame_aggregate
    t = CArray.time_range("2024-01-01T00:00", "2024-01-01T23:00", unit: :h)
    df = CAFrame.new("time" => t, "v" => CArray.float64(24).seq!).set_index("time")
    r = df.resample("time", "12 hours").aggregate("o" => ["v", :first], "c" => ["v", :last],
                                                  "n" => ["v", :nunique])
    assert_equal [0.0, 12.0], r["o"].to_a
    assert_equal [11.0, 23.0], r["c"].to_a
    assert_equal [12, 12], r["n"].to_a
    assert_equal CA_FLOAT64, r["o"].data_type
  end
end

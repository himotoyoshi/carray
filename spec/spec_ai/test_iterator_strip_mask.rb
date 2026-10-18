require "test/unit"
require "carray"

# strip_mask(method:) on an iterator member whose pieces do not overlap
# fills each masked cell from its own piece, as CArray#strip_mask(method:)
# fills the piece alone; the window iterator refuses. The members are
# collected, so a new member without a builder below fails.

class TestIteratorStripMask < Test::Unit::TestCase

  L  = 5
  P  = 3
  METHODS = %i[forward ffill backward bfill].freeze

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
      CAKeyWindowIterator   => nil,
      CASegmentIterator     => ->(d) { d.flatten.copy.segments(lengths: [L] * P) },
      CACategoricalIterator => ->(d) { d.flatten.copy.group_by_category(labels) },
      CAGroupIterator       => ->(d) { d.flatten.copy[labels] },
    }
  end

  def call (it, method)
    it.is_a?(CAGroupIterator) ? it.strip_mask(method: method, axis: :group) : it.strip_mask(method: method)
  end

  # Masked cells at the start, the end, in runs, and a piece with none present.
  MASKED = [[0, 2, 3], [4], [0, 1, 2, 3, 4]].freeze

  def data (type)
    d = CArray.int32(P, L) { |i, j| i * 10 + j }
    d = case type
        when :float64 then d.float64
        when :int32   then d
        when :object  then d.object
        when :time    then d.int64.time(unit: :D)
        end
    MASKED.each_with_index { |js, i| js.each { |j| d[i, j] = UNDEF } }
    d
  end

  def plain (row) = row.map { |x| x.is_a?(CATime::Element) ? x.to_s : x }

  def test_every_member_builds
    assert_equal [], self.class.iterator_classes - builders.keys
  end

  %i[float64 int32 object time].each do |type|
    define_method("test_each_piece_fills_as_the_core_#{type}") do
      d = data(type)
      diffs = []
      builders.each do |klass, build|
        next unless build
        METHODS.each do |method|
          got = call(build.(d), method).reshape(P, L)
          (0...P).each do |i|
            want = plain(d[i, nil].copy.strip_mask(method: method).to_a)
            have = plain(got[i, nil].to_a)
            diffs << "#{klass} #{method} row #{i}: #{have.inspect} != #{want.inspect}" unless have == want
          end
        end
      end
      assert_equal [], diffs
    end
  end

  def test_the_source_is_not_modified
    d = data(:float64)
    before = d.to_a
    builders.each_value { |build| call(build.(d), :ffill) if build }
    assert_equal before, d.to_a
  end

  # :linear needs a coordinate a piece does not have; anything else is not a
  # fill method.
  def test_refuses_other_methods
    d = data(:float64)
    builders.each do |klass, build|
      next unless build
      assert_raise(ArgumentError, "#{klass}") { call(build.(d), :linear) }
      assert_raise(ArgumentError, "#{klass}") { call(build.(d), :zero) }
    end
  end

  def test_window_refuses
    assert_raise(NotImplementedError) { CA_INT32([1, 2, 3]).windows(-1..1).strip_mask(method: :ffill) }
  end

  # A segment iterator finds every cell's source at once; empty segments,
  # segments at the ends and cells outside every segment are where that can
  # slip.
  def test_segment_random
    rng = Random.new(9)
    300.times do
      n = rng.rand(0..12)
      x = CArray.float64(n) { rng.rand(0..9).to_f }
      n.times { |i| x[i] = UNDEF if rng.rand < 0.4 }
      cuts = Array.new(rng.rand(1..5)) { rng.rand(0..n) }.sort
      %i[forward backward].each do |method|
        got = x.segments(offsets: cuts).strip_mask(method: method).to_a
        want = Array.new(n, UNDEF)
        (cuts.size - 1).times do |c|
          lo, hi = cuts[c], cuts[c + 1]
          want[lo...hi] = x[lo...hi].strip_mask(method: method).to_a if hi > lo
        end
        assert_equal want, got, "#{x.to_a.inspect} #{cuts.inspect} #{method}"
      end
    end
  end

  # A read-only Face cannot be written cell by cell, so it is filled as the
  # surface values it holds, as its reductions are collected.
  def test_categorical_value
    o = CA_OBJECT(%w[x y z w])
    o[2] = UNDEF
    it = o.categorize.group_by_category(CA_INT32([0, 1, 0, 1]).categorize)
    assert_equal %w[x y x w], it.strip_mask(method: :ffill).to_a
  end

  def test_categorical_axis_form
    m = CArray.float64(2, 4).seq!
    m[0, 1] = UNDEF
    m[1, 2] = UNDEF
    it = m.group_by_category(CA_INT32([0, 1, 0, 1]).categorize)
    assert_equal [[0.0, UNDEF, 2.0, 3.0], [4.0, 5.0, 4.0, 7.0]], it.strip_mask(method: :ffill, axis: 1).to_a
  end

  # A fill and a lag give the source's values held or moved in place, so
  # they show the source's attributes, as CArray#strip_mask and #lag do.
  def test_fill_and_lag_show_the_source_attributes
    builders.each do |klass, build|
      next unless build
      d = CArray.float64(P, L).seq
      d[0, 1] = UNDEF
      d.set_attr(:units, "K")
      it = build.(d)
      group = it.is_a?(CAGroupIterator) ? { axis: :group } : {}
      assert_equal({ "units" => "K" }, call(it, :ffill).attrs, "#{klass} strip_mask")
      assert_equal({ "units" => "K" }, it.lag(1, **group).attrs, "#{klass} lag")
    end
  end
end

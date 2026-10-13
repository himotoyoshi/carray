require "test/unit"
require "carray"

# A reduction's result cell is UNDEF when fewer cells contribute than it
# needs -- none for an operation with an identity, one for most, two for a
# sample variance -- or than min_count: asks for; fill_value: then fills it
# as a store of the value into that cell would.  Every iterator member
# answers each piece as the core answers that piece alone.  The iterator
# classes and the reductions are both collected, so a new member or a new
# reduction is checked without an entry here, and a member without a builder
# below fails.

class TestReducePresentCountMatrix < Test::Unit::TestCase

  L  = 3
  NP = [0, 1, 2, 3]          # present cells in each piece
  P  = NP.size
  MIN_COUNTS = [nil, 0, 1, 2, 3, 4]
  # fill_value: fills a result cell as a store of it into that cell would.
  FILLS = [7, 1.5, "2", UNDEF, nil]
  KEYWORDS = MIN_COUNTS.map { |mc| mc.nil? ? {} : { min_count: mc } } +
             FILLS.map { |fv| { min_count: 3, fill_value: fv } }
  ARGS = { percentile: [50], count: [21.0] }

  def self.iterator_classes
    Object.constants.grep(/Iterator\z/).each { |c| Object.const_get(c) }
    ObjectSpace.each_object(Class).select { |c| c < CAIterator }
  end

  def labels = CArray.object(P * L) { |i| "k#{i / L}" }.categorize(labels: (0...P).map { |i| "k#{i}" })

  # Each builds the iterator over the pieces (row i of d is piece i), and
  # gives the weights it takes and how to read one result per piece.
  def builders
    per_row = ->(r) { r }
    {
      CASlabIterator        => [->(d) { d[nil, :>] },                         ->(d) { ones(d, P, L) }, per_row],
      CABlockIterator       => [->(d) { d.flatten.copy.blocks(L) },            ->(d) { ones(d, L) },    per_row],
      CAWindowIterator      => [->(d) { d.flatten.copy.windows(0..L - 1, bounds: :truncate) },
                                ->(d) { ones(d, L) }, ->(r) { (0...P).map { |i| r[i * L] } }],
      CASegmentIterator     => [->(d) { d.flatten.copy.segments(lengths: [L] * P) }, ->(d) { ones(d, P * L) }, per_row],
      CAKeyWindowIterator   => [->(d) { d.flatten.copy.windows(on: CArray.int64(P * L) { |i| i / L }, before: 0, exclude: nil) },
                                ->(d) { ones(d, P * L) }, ->(r) { (0...P).map { |i| r[i * L] } }],
      CACategoricalIterator => [->(d) { d.flatten.copy.group_by_category(labels) }, ->(d) { ones(d, P * L) }, per_row],
      CAGroupIterator       => [->(d) { d.flatten.copy[labels] },              ->(d) { ones(d, P * L) }, per_row],
    }
  end

  # Weights of the data's own kind: an object array is weighted by objects,
  # so an exact value stays exact.
  def ones (d, *shape)
    d.data_type == CA_OBJECT ? CArray.object(*shape) { 1 } : CArray.float64(*shape) { 1.0 }
  end

  def call (obj, op, w, kw)
    args = op == :wsum || op == :wmean ? [w] : (ARGS[op] || [])
    kw = kw.merge(axis: :group) if obj.is_a?(CAGroupIterator)
    obj.public_send(op, *args, **kw)
  end

  def rows (r)
    r.is_a?(Array) ? r.map(&:to_a).transpose : r.to_a
  end

  def data (type)
    d = if type == :rational
          # an object array of exact values: every path answers exactly
          CArray.object(P, L) { |i, j| Rational(i * 10 + j + 1, j + 2) }
        else
          CArray.float64(P, L) { |i, j| (i + 1) * 10.0 + j + 1 }
        end
    d = d.to_type(type) unless type == :float64 || type == :rational
    NP.each_with_index { |n, i| (n...L).each { |j| d[i, j] = UNDEF } }
    d
  end

  # The reductions of the required surface that the core takes min_count:
  # for, found by asking the core.
  def reductions
    probe = CA_FLOAT64([1.0, 2.0])
    CAIterator::REQUIRED_SURFACE.select do |op|
      args = op == :wsum || op == :wmean ? [CA_FLOAT64([1, 1])] : (ARGS[op] || [])
      begin
        probe.public_send(op, *args, min_count: 1)
        true
      rescue ArgumentError, NoMethodError, LocalJumpError
        false
      end
    end
  end

  def same (a, b)
    return a.zip(b).all? { |x, y| same(x, y) } if a.is_a?(Array) && b.is_a?(Array) && a.size == b.size
    return a.equal?(b) if a.equal?(UNDEF) || b.equal?(UNDEF)
    return false unless a.class == b.class
    return (a.nan? && b.nan?) || (a - b).abs <= 1e-9 * [a.abs, 1].max if a.is_a?(Float)
    a == b
  end

  def test_every_member_builds
    assert_equal [], self.class.iterator_classes - builders.keys
  end

  def test_reductions_include_the_counted_family
    assert_include reductions, :sum
    assert_include reductions, :median
    assert_include reductions, :wmean
  end

  %i[float64 int32 object rational].each do |type|
    define_method("test_each_piece_answers_as_the_core_#{type}") do
      d = data(type)
      diffs = []
      builders.each do |klass, (build, weights, per_piece)|
        reductions.each do |op|
          KEYWORDS.each do |kw|
            got = begin
                    per_piece.(rows(call(build.(d), op, weights.(d), kw)))
                  rescue NotImplementedError
                    next
                  rescue => e
                    # a member that refuses the op for this type without a
                    # min_count does not provide it; only a refusal min_count
                    # brings about is a difference
                    plain = begin; call(build.(d), op, weights.(d), {}); nil; rescue => e0; e0; end
                    diffs << "#{klass} #{op} #{kw}: #{e.class}: #{e.message}" unless plain&.class == e.class
                    next
                  end
            (0...P).each do |i|
              piece = d[i, nil].copy
              args = op == :wsum || op == :wmean ? [ones(d, L)] : (ARGS[op] || [])
              want = piece.public_send(op, *args, **kw)
              want = want.to_a if want.is_a?(CArray)
              want = want.map { |x| x.is_a?(CArray) ? x.to_a : x } if want.is_a?(Array)
              # an address indexes the source, not the piece: compare where it is UNDEF
              if op == :min_addr || op == :max_addr
                ok = got[i].equal?(UNDEF) == want.equal?(UNDEF)
              else
                ok = same(got[i], want)
              end
              diffs << "#{klass} #{op} n=#{NP[i]} #{kw}: #{got[i].inspect} != #{want.inspect}" unless ok
            end
          end
        end
      end
      assert_equal [], diffs
    end
  end

  def test_window_order_statistics_leave_the_margin_out
    a = CA_FLOAT64([1, 5, 2, 8, 3])
    a[3] = UNDEF
    w = a.windows(-1..1)
    assert_equal w.reduce { |x| x.median }.to_a, w.median.to_a
    assert_equal [UNDEF, 2.0, UNDEF, UNDEF, UNDEF], w.percentile(50, min_count: 3).to_a
    b = CArray.float64(3, 4) { |i, j| ((i * 7 + j * 3) % 5) + 1.0 }
    b[1, 1] = UNDEF
    wb = b.windows(-1..1, -1..1)
    assert_equal wb.reduce { |x| x.median }.to_a, wb.median.to_a
  end

  def test_an_empty_group_has_no_weighted_mean
    v = CA_OBJECT([1, 2, 3])
    c = CArray.object(3) { "a" }.categorize(labels: %w[a b])
    assert_equal [2, UNDEF], v[c].wmean(CA_OBJECT([1, 1, 1]), axis: :group).to_a
  end

  def test_a_window_holding_only_nan_has_a_nan_extremum
    n = Float::NAN
    [CA_FLOAT64([3, n, 1, 2, n, n, 0, 0]), CA_OBJECT([3, n, 1, 2, n, n, 0, 0])].each do |a|
      a[6] = UNDEF
      a[7] = UNDEF
      w = a.windows(0..1, bounds: :truncate)
      assert_equal w.reduce { |x| x.min }.to_a.map(&:to_s), w.min.to_a.map(&:to_s)
      assert_equal w.reduce { |x| x.max }.to_a.map(&:to_s), w.max.to_a.map(&:to_s)
    end
  end
end

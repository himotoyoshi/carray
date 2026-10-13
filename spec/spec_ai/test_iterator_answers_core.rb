# Each reduction of an iterator is the core reduction lifted to the piece:
# `it.op` answers, piece by piece, what `piece.op` answers for the pieces
# `it.each` yields -- the same values, in the same data type.  The members
# answer by routes of their own for speed (fused kernels, a fold by offset,
# a C walk over a group), so this compares every member's answer with the
# core's over a spread of payloads, masks and pieces, including empty ones.
#
# Every CAIterator member is listed below with a recipe; a new member fails
# test_every_member_is_listed until it is added.  Values are compared as
# numbers (true and false as 1 and 0) and data types separately, against the
# core's answer along an axis of the piece.

require "test/unit"
require "carray"

class TestIteratorAnswersCore < Test::Unit::TestCase

  N = 20

  CODES   = [0, 1, 2, 0, 1, 2, 0, 1, 3, 0, 1, 2, 0, 1, 2, 0, 1, 2, 0, 1]
  OFFSETS = [0, 4, 4, 9, 15]                  # one segment is empty

  MEMBERS = {
    CASlabIterator        => ->(a) { a.reshape(4, 5)[nil, :>] },
    CAWindowIterator      => ->(a) { a.windows(-1..1) },
    CABlockIterator       => ->(a) { a.reshape(4, 5).blocks(3, 2) },
    CACategoricalIterator => ->(a) { a.group_by_category(CA_INT32(CODES).categorize) },
    CAGroupIterator       => ->(a) { a.reshape(4, 5)[CA_INT32([0, 1, 0, 1]).categorize, nil] },
    CASegmentIterator     => ->(a) { a.segments(offsets: CA_INT64(OFFSETS)) },
  }

  BASE = [3, -1, 0, 5, 2, 7, 1, 4, 6, -2]

  def self.values
    Array.new(N) { |i| BASE[i % 10] + i / 10 }
  end

  PAYLOADS = {
    int32:   -> { CArray.int32(N) { values } },
    uint8:   -> { CArray.uint8(N) { values.map(&:abs) } },
    float32: -> { CArray.float32(N) { values.map { |v| v * 0.5 } } },
    nan:     -> { a = CArray.float64(N) { values.map { |v| v * 0.25 } }; [3, 8, 12].each { |i| a[i] = Float::NAN }; a },
    boolean: -> { CArray.boolean(N) { values.map { |v| v > 2 ? 1 : 0 } } },
    object:  -> { CArray.object(N) { values.map { |v| Rational(v, 3) } } },
    time:    -> { CArray.time(values.map { |v| "2024-01-#{(v + 3).to_s.rjust(2, '0')}" }, unit: :D) },
  }

  MASKS = {
    none:    ->(a) { a },
    some:    ->(a) { a = a.copy; a[1] = UNDEF; a[6] = UNDEF; a },
    leading: ->(a) { a = a.copy; m = CArray.boolean(N); m[0...4] = 1; a[m] = UNDEF; a },
  }

  # The common surface, with the arguments each one is called with.  wsum /
  # wmean take a weight per member cell and are left to their own spec.
  OPS = {
    "sum"              => [:sum],
    "accumulate"       => [:accumulate],
    "prod"             => [:prod],
    "mean"             => [:mean],
    "min"              => [:min],
    "max"              => [:max],
    "variance"         => [:variance],
    "stddev"           => [:stddev],
    "variancep"        => [:variancep],
    "stddevp"          => [:stddevp],
    "all"              => [:all],
    "any"              => [:any],
    "minmax"           => [:minmax],
    "median"           => [:median],
    "percentile(30)"   => [:percentile, 30],
    "percentile(100)"  => [:percentile, 100],
    "quantile"         => [:quantile],
    "first"            => [:first],
    "last"             => [:last],
    "nunique"          => [:nunique],
    "count(1)"         => [:count, 1],
    "count_not_masked" => [:count_not_masked],
    "count_masked"     => [:count_masked],
    "sum(min_count: 3)"  => [:sum, { min_count: 3 }],
    "mean(min_count: 4)" => [:mean, { min_count: 4 }],
  }

  def test_every_member_is_listed
    members = ObjectSpace.each_object(Class).select { |c| c < CAIterator }
    assert_equal([], (members - MEMBERS.keys).map(&:name).sort,
                 "add a recipe that builds the member")
  end

  def test_each_reduction_is_the_core_one_per_piece
    failures = []
    PAYLOADS.each do |pname, payload|
      MASKS.each do |mname, mask|
        source = mask.(payload.())
        MEMBERS.each do |klass, recipe|
          it = recipe.(source)
          pieces = []
          it.each { |piece| pieces << piece.copy }
          OPS.each do |name, (op, *args)|
            kw = args.last.is_a?(Hash) ? args.pop : {}
            where = "#{klass.name}##{name} over #{pname} (#{mname})"
            got = answer { call(it, op, args, kw) }
            exp = pieces.map { |piece| answer { piece.public_send(op, *args, **kw) } }
            next if exp.all? { |e| e.is_a?(Exception) } && got.is_a?(Exception)
            if got.is_a?(Exception)
              failures << "#{where}: raised #{got.class}: #{got.message[0, 80]}"
              next
            end
            got_values = per_piece(got, klass, pieces.size)
            unless numbers(got_values) == numbers(exp)
              failures << "#{where}: #{numbers(got_values).inspect[0, 120]} " \
                          "!= #{numbers(exp).inspect[0, 120]}"
              next
            end
            type = core_type(pieces, op, args, kw)
            next if type.nil?
            got_type = (got.is_a?(Array) ? got.first : got).data_type
            failures << "#{where}: data type #{got_type} != #{type}" unless got_type == type
          end
        end
      end
    end
    assert_equal([], failures)
  end

  private

  def answer
    yield
  rescue StandardError => e
    e
  end

  def call (it, op, args, kw)
    if it.is_a?(CAGroupIterator)
      it.public_send(op, *args, axis: :group, **kw)
    else
      it.public_send(op, *args, **kw)
    end
  end

  # The answer as one entry per piece, in the order `each` yields them.  A
  # group yields band by band, each band's groups in turn, where its answer
  # is laid out group by band.  An answer of several arrays (quantile,
  # minmax) is one tuple per piece.
  def per_piece (got, klass, count)
    if got.is_a?(Array)
      return got.map { |x| per_piece(x, klass, count) }.transpose
    end
    cells = got.to_a
    cells = cells.transpose if klass == CAGroupIterator
    cells = cells.flatten
    assert_equal(count, cells.size)
    cells
  end

  def numbers (x)
    case x
    when Array     then x.map { |v| numbers(v) }
    when true      then 1
    when false     then 0
    when Float     then x.nan? ? :nan : x.round(9)
    when Rational  then x.to_f.round(9)
    when Integer   then x.to_f.round(9)
    when Exception then :raised
    else x.respond_to?(:to_s) && x.class.name.to_s.end_with?("Element") ? x.to_s : x
    end
  end

  # The core's data type for the reduction along an axis of a piece: what a
  # per-piece answer is a cell of.  Nil when the core does not answer that
  # way for any piece (it refuses, or answers several arrays).
  def core_type (pieces, op, args, kw)
    pieces.each do |piece|
      flat = piece.reshape(1, piece.elements)
      r = begin
            flat.public_send(op, *args, axis: 1, **kw)
          rescue StandardError
            nil
          end
      return r.data_type if r.is_a?(CArray)
    end
    nil
  end

end

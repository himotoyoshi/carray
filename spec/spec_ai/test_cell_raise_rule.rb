require 'test/unit'
require 'carray'

# A kernel that can raise on a cell does not compute the cells its operands
# mask: an object cell (it calls Ruby), an integer division, remainder or
# reciprocal by zero, an integer power of zero to a negative exponent.  The
# eager operators, the lazy views and the plans an evaluator is handed
# follow one rule.  The operations are taken from the lazy tables, so a new
# one is measured as it lands.
class TestCellRaiseRule < Test::Unit::TestCase

  class Boom
    def method_missing (*) = raise(ArgumentError, "boom")
    def respond_to_missing? (*) = true
    def coerce (_) = raise(ArgumentError, "boom")
  end
  BOOM = Boom.new

  TYPES = %i[int8 uint8 int32 int64 uint64 float32 float64 cmplx128 object boolean]

  OPS = (
    CArray::LAZY_MONOP_OP_IDS.keys.map  { |m| [:monop,  m, ->(a, b, c) { a.send(m) }] } +
    CArray::LAZY_BINOP_OP_IDS.keys.map  { |m| [:binop,  m, ->(a, b, c) { a.send(m, b) }] } +
    CArray::LAZY_TRIOP_OP_IDS.keys.map  { |m| [:triop,  m, ->(a, b, c) { a.send(m, b, c) }] } +
    CArray::LAZY_BINCMP_OP_IDS.keys.map { |m| [:bincmp, m, ->(a, b, c) { a.send(m, b) }] } +
    CArray::LAZY_MONCMP_OP_IDS.keys.map { |m| [:moncmp, m, ->(a, b, c) { a.send(m) }] }
  )

  def self.trouble (t)
    case t
    when :object  then BOOM
    when :boolean then false
    when :float32, :float64, :cmplx128 then Float::NAN
    else 0
    end
  end

  def self.benign (t)
    t == :boolean ? [true, false] : [2, 3]
  end

  # Three cells holding first, then the benign values; masked at 0 if asked.
  def self.cells (t, first, masked)
    a = CArray.new(t, [3])
    [first, *benign(t)].each_with_index do |v, i|
      begin
        a[i] = v
      rescue StandardError
        a[i] = benign(t)[0]
      end
    end
    a[0] = UNDEF if masked
    a
  end

  def answer
    x = yield
    x = x.copy if x.is_a?(CArray)
    x.is_a?(CArray) ? [x.data_type, x.to_a.map { |e| e.is_a?(Float) && e.nan? ? :nan : e }] : x
  rescue StandardError, NotImplementedError => e
    e.class
  end

  def test_a_masked_cell_is_not_computed
    wrong = []
    TYPES.each do |t|
      OPS.each do |kind, m, f|
        args = Array.new(3) { self.class.cells(t, self.class.trouble(t), true) }
        eager = answer { f.(*args) }
        lazy  = answer { f.(*args.map(&:lazy)) }
        plain = answer { f.(*Array.new(3) { self.class.cells(t, self.class.benign(t)[0], false) }) }
        wrong << "#{t} #{kind} #{m}: eager #{eager.inspect[0, 60]} / lazy #{lazy.inspect[0, 60]}" unless eager == lazy
        wrong << "#{t} #{kind} #{m}: a masked cell raised #{eager}" if eager.is_a?(Class) && !plain.is_a?(Class)
      end
    end
    assert_equal [], wrong
  end

  # The rule a lazy node reports (and a plan carries) covers the kernel: an
  # operation whose kernel raises for some cell value, where it does not
  # for others, reports that a masked cell must be skipped.  Reporting more
  # than that (an object cell may call Ruby; an unsigned power never gets a
  # negative exponent) only costs the skip.
  def test_the_reported_rule_covers_the_kernel
    wrong = []
    TYPES.each do |t|
      tr = self.class.trouble(t)
      ok = self.class.benign(t)[0]
      firsts = [tr, -1, ok]
      OPS.each do |kind, m, f|
        node = begin
          f.(*Array.new(3) { self.class.cells(t, ok, false).lazy })
        rescue StandardError, NotImplementedError
          next
        end
        next unless node.is_a?(CArray) && node.respond_to?(:__trapping__)
        run = ->(x, y) {
          answer { f.(self.class.cells(t, x, false), self.class.cells(t, y, false),
                      self.class.cells(t, x, false)) }.is_a?(Class)
        }
        next if run.(ok, ok)                       # refused for the type, not a cell
        raises = firsts.product(firsts).any? { |x, y| run.(x, y) }
        wrong << "#{t} #{kind} #{m}: raises on a cell, reports false" if raises && !node.__trapping__
      end
    end
    assert_equal [], wrong
  end

  def test_an_object_cell_is_always_skipped
    OPS.each do |kind, m, f|
      node = begin
        f.(*Array.new(3) { self.class.cells(:object, 2, false).lazy })
      rescue StandardError, NotImplementedError
        next
      end
      next unless node.is_a?(CArray) && node.respond_to?(:__trapping__)
      assert_equal true, node.__trapping__, "#{kind} #{m}"
    end
  end
end

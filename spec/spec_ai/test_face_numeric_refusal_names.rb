# frozen_string_literal: true
#
# A numeric operation a Face does not define is refused by naming the
# method and the Face's class, and pointing at its values and its storage --
# not by the fixlen surface that gates it. A plain array whose data type has
# no kernel names the method and the type.

require "test/unit"
require_relative "../../lib/carray"

class TestFaceNumericRefusalNames < Test::Unit::TestCase

  class Plain < CAObject
    def initialize(parent)
      super(parent.data_type, parent.dim, parent: parent, face: true)
    end
  end

  def setup
    @f = Plain.new(CA_FLOAT64([1.0, 2.0]))
    @g = Plain.new(CA_FLOAT64([3.0, 4.0]))
  end

  REFUSED = {
    "+"          => ->(f, g) { f + g },
    "neg"        => ->(f, g) { -f },
    "abs"        => ->(f, g) { f.abs },
    "sqrt"       => ->(f, g) { f.sqrt },
    "is_nan"     => ->(f, g) { f.is_nan },
    "fma"        => ->(f, g) { f.fma(g, g) },
    "sum"        => ->(f, g) { f.sum },
    "mean"       => ->(f, g) { f.mean },
    "variance"   => ->(f, g) { f.variance },
    "cumsum"     => ->(f, g) { f.cumsum },
    "accumulate" => ->(f, g) { f.accumulate },
    "median"     => ->(f, g) { f.median },
    "percentile" => ->(f, g) { f.percentile(50) },
  }

  REFUSED.each do |name, op|
    define_method("test_#{name.tr('+', 'plus')}_names_the_face") do
      e = assert_raise(CArray::DataTypeError) { op.call(@f, @g) }
      assert_match(/\A#{Regexp.escape(name)}: .*Plain does not define it/, e.message)
      assert_match(/to_type\(:object\) gives its values/, e.message)
      assert_match(/\.parent/, e.message)
      assert_not_match(/fixlen/, e.message)
    end
  end

  def test_a_plain_array_names_the_method_and_the_type
    x = CArray.new(CA_FIXLEN, [2], bytes: 4)
    e = assert_raise(CArray::DataTypeError) { x.sqrt }
    assert_equal "sqrt: not defined for data_type fixlen", e.message
    e = assert_raise(CArray::DataTypeError) { x + x }
    assert_equal "+: not defined for data_type fixlen", e.message
  end

  def test_a_numeric_face_still_computes
    n = Class.new(CAObject) do
      def initialize(p) = super(p.data_type, p.dim, parent: p, face: true, numeric: true)
    end.new(CA_FLOAT64([1.0, 4.0]))
    assert_equal [1.0, 2.0], n.sqrt.to_a
    assert_equal 5.0, n.sum
  end
end

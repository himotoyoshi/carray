# examples/face/ca_quantity.rb
#
# CAQuantity — a float array that carries one physical unit.
#
# A Face over float storage, NonNumeric by default, that brings back the
# operations which stay in the same unit: adding and subtracting quantities
# (converting the other operand's unit), negation, abs, multiplying or
# dividing by a plain number, and the reductions sum, cumsum, mean, median,
# percentile and stddev. Their results are quantities again. Ordering
# (min, max, sort, search, comparisons) comes from the core through
# orderable_storage and to_comparable.
#
# What stays refused is everything that would change the unit or has no
# unit-respecting meaning: quantity × quantity (m²), variance (m²), sqrt,
# exp, log, sin. Units of one dimension convert into each other (`to(:km)`);
# there is no unit algebra between dimensions.
#
# Every unit here is a pure scale (value = factor × number in the base
# unit). Celsius is not offered: its zero is offset, so 10 °C + 10 °C is
# not 20 °C. Kelvin is.
#
# Usage:
#   require 'carray'
#   require_relative 'examples/face/ca_quantity'
#
#   h = CAQuantity.new(CA_FLOAT64([152.0, 168.5, 175.0]), :cm)
#   h.mean                 # => 165.17 cm
#   (h - h.mean).to_a      # => [-13.17 cm, 3.33 cm, 9.83 cm]
#   h > CAQuantity::Value.new(1.6, :m)              # => [false, true, true]
#   h.to(:m).max           # => 1.75 m
#   h + CAQuantity.new(CA_FLOAT64([1, 1, 1]), :m)   # => [252.0 cm, ...]
#   h * h                  # => TypeError (cm² is not cm)

require "carray"

class CAQuantity < CAObject

  # unit => [dimension, factor to the dimension's base unit]
  UNITS = {
    m:   [:length, 1.0],  km:  [:length, 1000.0], cm: [:length, 0.01],
    mm:  [:length, 0.001],
    s:   [:time, 1.0],    min: [:time, 60.0],     h:  [:time, 3600.0],
    kg:  [:mass, 1.0],    g:   [:mass, 0.001],
    K:   [:temperature, 1.0],
    Pa:  [:pressure, 1.0], hPa: [:pressure, 100.0],
  }.freeze

  def self.dimension_of(unit)
    UNITS.fetch(unit) { raise ArgumentError, "unknown unit #{unit.inspect}" }[0]
  end

  def self.factor(from, to)
    df, ff = UNITS.fetch(from) { raise ArgumentError, "unknown unit #{from.inspect}" }
    dt, ft = UNITS.fetch(to)   { raise ArgumentError, "unknown unit #{to.inspect}" }
    raise TypeError, "can't convert #{from} (#{df}) to #{to} (#{dt})" if df != dt
    ff / ft
  end

  # One value with its unit.
  class Value
    include Comparable
    attr_reader :value, :unit
    def initialize(value, unit); @value = value; @unit = unit; end
    def to(unit);   Value.new(@value * CAQuantity.factor(@unit, unit), unit); end
    def to_f;       @value.to_f; end
    def to_s;       "#{@value.round(2)} #{@unit}"; end
    def inspect;    "#<#{to_s}>"; end
    def <=>(other)
      return nil unless other.is_a?(Value) &&
                        CAQuantity.dimension_of(other.unit) == CAQuantity.dimension_of(@unit)
      @value <=> other.to(@unit).value
    end
  end

  def initialize(parent, unit)
    unless [:float32, :float64].include?(parent.data_type)
      raise TypeError, "CAQuantity stores float32 or float64 (got #{parent.data_type})"
    end
    CAQuantity.dimension_of(unit)
    @unit = unit
    super(parent.data_type, parent.dim, parent: parent, face: true,
          orderable_storage: true)
  end

  attr_reader :unit

  def dimension = CAQuantity.dimension_of(@unit)

  # ---- Face callbacks ----

  def copy_state(src);         @unit = src.unit;               end
  def storage_to_element(raw); Value.new(raw, @unit);           end

  # A bare number has no unit, so it is refused; write the storage
  # directly (`q.parent[i] = x`) to store one in this array's unit.
  def element_to_storage(v)
    raise TypeError, "store a CAQuantity::Value, not #{v.class}" unless v.is_a?(Value)
    v.to(@unit).value
  end

  # A query of another unit is converted before the ordering family
  # (sort, search, linear_section, ...) reads it as a stored number.
  def to_comparable(operand)
    case operand
    when Value      then operand.to(@unit).value
    when CAQuantity then operand.to(@unit).parent
    else raise TypeError, "compare a #{self.class} with a quantity, not #{operand.class}"
    end
  end

  # The values as plain numbers, in this array's unit.
  def to_numeric = parent

  # ---- unit conversion ----

  def to(unit)
    return self if unit == @unit
    self.class.new(parent * CAQuantity.factor(@unit, unit), unit)
  end

  # ---- staying in the unit: storage computes, the result is wrapped ----

  def +(other) = wrap(parent + in_my_unit(other))
  def -(other) = wrap(parent - in_my_unit(other))
  def -@       = wrap(-parent)
  def abs      = wrap(parent.abs)

  def *(factor) = wrap(parent * plain_number(factor, "*"))
  def /(divisor)
    # A ratio of two quantities of one dimension is a plain number.
    return parent / in_my_unit(divisor) if divisor.is_a?(CAQuantity) || divisor.is_a?(Value)
    wrap(parent / plain_number(divisor, "/"))
  end

  def sum(...)        = wrap(parent.sum(...))
  def cumsum(...)     = wrap(parent.cumsum(...))
  def mean(...)       = wrap(parent.mean(...))
  def median(...)     = wrap(parent.median(...))
  def percentile(...) = wrap(parent.percentile(...))
  def stddev(...)     = wrap(parent.stddev(...))

  # min, max, sort, search and the comparisons (< > eq ...) need no code
  # here: orderable_storage lets the core run them on the stored numbers,
  # reading a quantity operand through to_comparable.

  private

  def in_my_unit(other)
    case other
    when CAQuantity then other.to(@unit).parent
    when Value      then other.to(@unit).value
    else raise TypeError, "a #{self.class} meets a quantity, not #{other.class}"
    end
  end

  def plain_number(x, op)
    return x if x.is_a?(Numeric) && !x.is_a?(Complex)
    return x if x.is_a?(CArray) && !x.face?
    raise TypeError, "#{self.class} #{op} #{x.class}: a quantity is scaled by a plain number"
  end

  def wrap(result)
    case result
    when CArray  then self.class.new(result, @unit)
    when Numeric then Value.new(result, @unit)
    else result                         # UNDEF
    end
  end
end

# ----------------------------------------------------------------------
# Demo (run when this file is executed directly)
# ----------------------------------------------------------------------
if __FILE__ == $0
  h = CAQuantity.new(CA_FLOAT64([152.0, 168.5, 175.0, 160.0]), :cm)
  puts "heights          #{h.to_a.map(&:to_s).join(', ')}"
  puts "mean             #{h.mean}"
  puts "median           #{h.median}"
  puts "stddev           #{h.stddev}"
  puts "max in m         #{h.to(:m).max}"
  puts "deviation        #{(h - h.mean).to_a.map(&:to_s).join(', ')}"
  puts "+ 1 m            #{(h + CAQuantity::Value.new(1.0, :m)).to_a.map(&:to_s).join(', ')}"
  puts "taller than 1.6 m: #{(h > CAQuantity::Value.new(1.6, :m)).to_a.inspect}"
  puts "sorted           #{h.sort.to_a.map(&:to_s).join(', ')}"
  puts "h[1..2]          #{h[1..2].class} #{h[1..2].unit}"
  puts
  puts "refused:"
  [["h * h", -> { h * h }], ["h.variance", -> { h.variance }],
   ["h.sqrt", -> { h.sqrt }], ["h + 1", -> { h + 1 }],
   ["h + 1 s", -> { h + CAQuantity::Value.new(1.0, :s) }]].each do |label, f|
    begin
      f.call
      puts "  #{label}: (no error)"
    rescue => e
      puts "  #{label}: #{e.class}"
    end
  end
end

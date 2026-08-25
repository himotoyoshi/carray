# samples/ca_circular.rb
#
# CACircular — angles as a semantic type, the reference implementation of a
# Face written in Ruby.  A CAObject Face over float64 storage, holding a
# circular range (0..2*pi, or 0..360 degrees) and carrying circular
# statistics.
#
# It shows what the Face mechanism and CAObject buy together: a semantic type
# written in Ruby alone, which always sits at the top of a view chain.
# Referenced as the example in docs/topics/CAFace.md §3.
#
# Usage:
#   require 'carray'
#   require_relative 'samples/ca_circular'
#
#   angles = CArray.float64(5)
#   [0.0, Math::PI/4, Math::PI/2, 3*Math::PI/4, Math::PI].each_with_index {|v, i|
#     angles[i] = v
#   }
#   cc = CACircular.new(angles, range: :rad)
#   cc.circular_mean           # => pi/2 (the centre)
#   cc[1..3].circular_mean     # works on a sliced view too
#   cc.flip.range              # => :rad — the range survives the chain

require "carray"

class CACircular < CAObject
  RANGES = [:rad, :deg].freeze

  def initialize(parent, range: :rad)
    unless RANGES.include?(range)
      raise ArgumentError, "range must be :rad or :deg (got #{range.inspect})"
    end
    @range = range
    super(CA_FLOAT64, parent.dim, parent: parent, face: true)
  end

  attr_reader :range

  # Face callback — carries the ivars, so state survives a sliced view
  def copy_state(src)
    @range = src.range
  end

  # Face callback — what `cc[i]` wraps into (optional)
  def storage_to_scalar(raw)
    Scalar.new(raw, @range)
  end

  # ----- circular statistics -----

  # Mean angle = atan2(mean_sin, mean_cos)
  # Reference: Mardia & Jupp, "Directional Statistics" §1.3
  def circular_mean
    vals = self.to_a.map {|s| s.is_a?(Scalar) ? s.value : s}
    factor = (@range == :deg) ? (Math::PI / 180.0) : 1.0
    sum_sin = vals.sum {|v| Math.sin(v * factor)}
    sum_cos = vals.sum {|v| Math.cos(v * factor)}
    mean_rad = Math.atan2(sum_sin / vals.size, sum_cos / vals.size)
    mean_rad += 2 * Math::PI if mean_rad < 0
    (@range == :deg) ? mean_rad * 180.0 / Math::PI : mean_rad
  end

  # Resultant length R = sqrt(mean_sin^2 + mean_cos^2)
  # R is in [0, 1]: 1 is perfectly concentrated, 0 perfectly dispersed
  def resultant_length
    vals = self.to_a.map {|s| s.is_a?(Scalar) ? s.value : s}
    factor = (@range == :deg) ? (Math::PI / 180.0) : 1.0
    mean_sin = vals.sum {|v| Math.sin(v * factor)} / vals.size
    mean_cos = vals.sum {|v| Math.cos(v * factor)} / vals.size
    Math.sqrt(mean_sin**2 + mean_cos**2)
  end

  # Circular variance = 1 - R
  def circular_variance
    1.0 - resultant_length
  end

  # Circular standard deviation = sqrt(-2 * log(R))
  def circular_stddev
    r = resultant_length
    return Float::INFINITY if r <= 0
    Math.sqrt(-2.0 * Math.log(r))
  end

  # ----- Scalar -----

  class Scalar
    attr_reader :value, :unit

    def initialize(value, unit)
      @value = value
      @unit = unit
    end

    # convert between radians and degrees
    def to_rad
      @unit == :rad ? @value : @value * Math::PI / 180.0
    end

    def to_deg
      @unit == :deg ? @value : @value * 180.0 / Math::PI
    end

    def to_s
      "#<CACircular::Scalar #{@value.round(4)} #{@unit}>"
    end

    alias inspect to_s
  end
end

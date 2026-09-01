# examples/face/ca_fixed_point.rb
#
# CAFixedPoint — a NonNumeric Face that stores values as int64 with a
# decimal scale (= e.g. prices in cents, durations in millis).
#
# This is the canonical reference for the Z-pilot `:storage` opt-in:
# a Ruby Face whose surface declares `CA_FIXLEN` so that all mkkernel
# numeric dispatch is gated off, and whose Ruby override layer routes
# the permitted operations (+, -, *, /, sum, mean, comparison, …)
# through the int64 parent.
#
# Why NonNumeric for fixed-point? The whole raison d'être of fixed-point
# is to avoid Float round-trip drift.  A Numeric Face (surface = INT64)
# would let `fp * 0.5` silently promote the buffer to float64, destroying
# the int64-storage invariant that defines fixed-point.  The CA_FIXLEN
# surface forces every value-bearing op through an explicit override
# that round-and-stores back to int64.
#
# Usage:
#   require 'carray'
#   require_relative 'examples/face/ca_fixed_point'
#
#   cents  = CArray.int64(5) { |i| [12345, 13020, 12875, 13510, 13200][i] }
#   prices = CAFixedPoint.new(cents, scale: 100)
#   prices[0]                        # => #<Scalar 123.45>
#   prices.mean                      # => #<Scalar 129.90>
#   (prices * 0.95).parent.data_type # => :int64 (5% discount, no FP drift)
#   prices > 130.0                   # => CArray boolean mask
#   prices.cumprod                   # => TypeError (gated, scale would explode)
#
# Caveats (= documented limitations):
# - `2 * fp` does NOT work (= Ruby coerce protocol is bypassed by
#   CArray's own binop driver). Write `fp * 2` instead.
# - `sum` on a large array can overflow int64; convert to Bignum via
#   `parent.to_a.sum` if values approach 2^63 / scale.
# - `scale` must be a positive Integer; powers of 10 are assumed for
#   the default decimal display.  For non-10 scales, override `to_s`
#   on Scalar.
# - `+/-` treat Numeric operands as **values** (= `× scale`, rounded);
#   `*//` treat Numeric operands as **coefficients** (= no scale shift).
#   This is the affine-vs-linear distinction inherent in fixed-point.

require "carray"

class CAFixedPoint < CAObject
  def initialize(parent_int64, scale: 1000)
    raise TypeError, "CAFixedPoint requires int64 parent" unless parent_int64.data_type == :int64
    raise ArgumentError, "scale must be positive Integer" unless scale.is_a?(Integer) && scale > 0
    @scale = scale
    @frac_digits = Math.log10(scale).round
    super(CA_FIXLEN, parent_int64.dim,
          bytes: 8, storage: CA_INT64,
          parent: parent_int64, face: true)
  end

  attr_reader :scale, :frac_digits

  def copy_state(src)
    @scale = src.scale
    @frac_digits = src.frac_digits
  end

  def storage_to_scalar(raw)
    int_val = raw.is_a?(String) ? raw.unpack1('q') : raw
    Scalar.new(int_val, @scale)
  end

  # Per-cell wrap.  C-struct Scalar would be faster, but a plain Ruby
  # class keeps the sample readable.  See CADatetime::Scalar in
  # ext/ca_obj_datetime.c for the C-struct pattern.
  class Scalar
    include Comparable
    attr_reader :raw, :scale

    def initialize(raw, scale); @raw = raw; @scale = scale; end
    def to_f;    @raw.to_f / @scale; end
    def to_s;    format("%.#{Math.log10(@scale).round}f", to_f); end
    def inspect; "#<#{self.class} #{to_s} (raw=#{@raw}, scale=#{@scale})>"; end

    def <=>(other)
      return nil unless other.is_a?(Scalar) && other.scale == @scale
      @raw <=> other.raw
    end

    def ==(other)
      other.is_a?(Scalar) && other.scale == @scale && other.raw == @raw
    end
  end

  # ---- arithmetic (affine: Numeric operand = value, × scale, rounded) ----
  def +(other); self.class.new(parent + coerce_as_value(other), scale: @scale); end
  def -(other); self.class.new(parent - coerce_as_value(other), scale: @scale); end
  def -@;       self.class.new(-parent, scale: @scale); end

  # ---- arithmetic (linear: Numeric operand = coefficient, no scale shift) ----
  def *(factor)
    raise TypeError, "fixed * fixed needs explicit rescale (use #mul_fixed)" if factor.is_a?(CAFixedPoint)
    raise TypeError, "cannot multiply by #{factor.class}" unless factor.is_a?(Numeric)
    self.class.new((parent.float64 * factor).round.int64, scale: @scale)
  end

  def /(divisor)
    raise TypeError, "fixed / fixed needs explicit rescale" if divisor.is_a?(CAFixedPoint)
    raise TypeError, "cannot divide by #{divisor.class}" unless divisor.is_a?(Numeric)
    raise ZeroDivisionError if divisor == 0
    self.class.new((parent.float64 / divisor).round.int64, scale: @scale)
  end

  # ---- numeric conversion (the NonNumeric Face's half of the cast) ----

  # A CA_FIXLEN surface gates the numeric kernels off, so the core cannot
  # read a number out of this array on its own -- the storage is scaled
  # integers, and only the Face knows the scale.  #to_numeric is where the
  # Face says it: return the values as a plain CArray and every numeric cast
  # follows from it.
  #
  #   prices.to_type(:float64)   # => [123.45, 130.20, 128.75]
  #   prices.float64             # same, via the short-hand
  #
  # It is array-level (not a per-cell Scalar#to_f) so the conversion stays
  # vectorised: 1.45 ms against 449 ms per million cells.
  def to_numeric
    parent.float64 / @scale.to_f
  end

  # ---- scale conversion ----
  def rescale(new_scale)
    raise ArgumentError, "scale must be positive Integer" unless new_scale.is_a?(Integer) && new_scale > 0
    return self if new_scale == @scale
    factor = new_scale.to_f / @scale
    self.class.new((parent.float64 * factor).round.int64, scale: new_scale)
  end

  def mul_fixed(other, result_scale: @scale)
    raise TypeError unless other.is_a?(CAFixedPoint)
    intermediate_scale = @scale * other.scale
    factor = result_scale.to_f / intermediate_scale
    raw = (parent.float64 * other.parent.float64 * factor).round.int64
    self.class.new(raw, scale: result_scale)
  end

  # ---- reductions (axis-aware) ----
  def sum(*args, **opts);  wrap_reduction(parent.sum(*args, **opts));  end
  def min(*args, **opts);  wrap_reduction(parent.min(*args, **opts));  end
  def max(*args, **opts);  wrap_reduction(parent.max(*args, **opts));  end

  def mean(*args, **opts)
    s = parent.sum(*args, **opts)
    n = s.is_a?(CArray) ? (parent.elements / s.elements) : parent.elements
    wrap_reduction(round_div(s, n))
  end

  # ---- comparison (arrays produce boolean masks; same-scale only) ----
  def <(other);  parent <  coerce_as_value(other); end
  def <=(other); parent <= coerce_as_value(other); end
  def >(other);  parent >  coerce_as_value(other); end
  def >=(other); parent >= coerce_as_value(other); end

  def ==(other)
    return false unless other.is_a?(CAFixedPoint) && other.scale == @scale
    parent == other.parent
  end

  private

  def coerce_as_value(other)
    case other
    when CAFixedPoint
      raise TypeError, "scale mismatch (#{@scale} vs #{other.scale})" if other.scale != @scale
      other.parent
    when Float, Integer, Rational
      (other.to_f * @scale).round
    else
      raise TypeError, "cannot coerce #{other.class} to CAFixedPoint(scale=#{@scale})"
    end
  end

  def wrap_reduction(result)
    case result
    when CArray   then self.class.new(result.int64, scale: @scale)
    when Integer  then Scalar.new(result, @scale)
    when Numeric  then Scalar.new(result.round, @scale)
    else raise TypeError, "unexpected reduction result: #{result.class}"
    end
  end

  def round_div(a, n)
    case a
    when CArray  then (a.float64 / n.to_f).round.int64
    when Integer then ((a * 2 + (a >= 0 ? n : -n)) / (2 * n))
    else (a.to_f / n).round
    end
  end
end

# ----------------------------------------------------------------------
# Demo (run when this file is executed directly)
# ----------------------------------------------------------------------
if __FILE__ == $0
  puts "=== 5 days of stock closing prices (scale=100, cents) ==="
  cents  = CArray.int64(5) { |i| [12345, 13020, 12875, 13510, 13200][i] }
  prices = CAFixedPoint.new(cents, scale: 100)
  %w[Mon Tue Wed Thu Fri].zip(prices.to_a).each { |d, p| puts "  #{d}: $#{p}" }

  puts ""
  puts "=== internal representation ==="
  puts "  parent.data_type = #{prices.parent.data_type}  (int64 cents, no FP drift)"
  puts "  parent.to_a      = #{prices.parent.to_a.inspect}"
  puts "  data_type        = #{prices.data_type}        (surface FIXLEN, gates numeric ops)"

  puts ""
  puts "=== summary stats ==="
  puts "  max  = $#{prices.max}     min  = $#{prices.min}"
  puts "  mean = $#{prices.mean}    sum  = $#{prices.sum}"

  puts ""
  puts "=== arithmetic ==="
  puts "  prices + $1.50:  #{(prices + 1.50).to_a.map { |p| '$' + p.to_s }.inspect}"
  puts "  prices × 0.95 (5% discount):  #{(prices * 0.95).to_a.map { |p| '$' + p.to_s }.inspect}"
  puts "  ↳ result.parent.data_type = #{(prices * 0.95).parent.data_type} (still int64, no FP drift)"

  puts ""
  puts "=== mask: prices > $130 ==="
  mask = prices > 130.0
  %w[Mon Tue Wed Thu Fri].zip(prices.to_a, mask.to_a).each { |d, p, m|
    puts "  #{d}: $#{p}#{m == 1 ? '  ← over $130' : ''}"
  }

  puts ""
  puts "=== forbidden ops (would corrupt scale or unit) ==="
  [
    ["prices.cumprod (= cents^N, scale explodes)",    -> { prices.cumprod }],
    ["Math.sqrt(prices[0]) (= sqrt of cents)",         -> { Math.sqrt(prices[0]) }],
    ["prices * prices (= cents², needs rescale)",      -> { prices * prices }],
  ].each do |label, blk|
    begin; blk.call; puts "  ✗ LEAK: #{label}"
    rescue => e; puts "  ✓ #{label} → TypeError"; end
  end

  puts ""
  puts "=== FP drift comparison ==="
  sum = 0.0; 10.times { sum += 0.1 }
  puts "  Float loop accumulator (0.1 × 10): #{sum}"
  ten_dimes = CAFixedPoint.new(CArray.int64(10) { 10 }, scale: 100)
  puts "  CAFixedPoint sum:                   $#{ten_dimes.sum}"

  puts ""
  puts "=== view chain (Face + scale carry) ==="
  puts "  prices[1..3].class = #{prices[1..3].class}, scale = #{prices[1..3].scale}"
  puts "  prices.flip.to_a   = #{prices.flip.to_a.map(&:to_s).inspect}"
end

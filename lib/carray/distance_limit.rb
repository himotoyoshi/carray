# frozen_string_literal: true

class CArray

  # The length a match by distance is limited by -- the +tolerance:+ of
  # locate_nearest_addr (and of align_nearest_addr and CAFrame#join_asof
  # through it), the +before:+, +after:+ and +interval:+ of a key window --
  # read the same way wherever it is given: a length of the key's kind,
  # not below 0.
  #
  # - For a number key it is a real number; NaN, which no distance is
  #   within or beyond, and a negative length are refused, as is a String.
  # - For a time or duration key it is a duration: a String such as
  #   "10 minutes" (and "0 minutes") or a CATimedelta value, not negative.
  #   A bare number is refused, since its length would depend on the key's
  #   unit.
  #
  # Every refusal is ArgumentError naming +label+, the keyword as the
  # caller says it ("tolerance:", "windows: before:").
  module DistanceLimit

    ZERO_DURATION = /\A\s*0+\s+([A-Za-z]+)\s*\z/

    # +width+ as a Numeric (number key) or a CATimedelta::Element (time or
    # duration key); +nil+ passes through.
    def self.read (width, key, label)
      return nil if width.nil?
      if key.is_a?(CATime) || key.is_a?(CATimedelta)
        duration(width, label)
      else
        number(width, key, label)
      end
    end

    def self.number (width, key, label)
      if width.is_a?(String) || width.is_a?(CATimedelta::Element)
        raise ArgumentError,
              "#{label} #{width.inspect} is a duration, but the key is " \
              "#{CArray::Inspector.type_label(key)}; give a number"
      end
      unless width.is_a?(Numeric) && width.real? && !(width.is_a?(Float) && width.nan?) && width >= 0
        raise ArgumentError, "#{label} is a number not below 0 (got #{width.inspect})"
      end
      width
    end

    def self.duration (width, label)
      element =
        case width
        when CATimedelta::Element
          width
        when String
          if (zero = width.match(ZERO_DURATION))
            CATimedelta::Element.new(0, CATime::Resolution.parse(zero[1]).base)
          else
            res = begin
                    CATime::Resolution.parse(width)
                  rescue ArgumentError
                    raise ArgumentError,
                          "#{label} #{width.inspect} is not a duration " \
                          "(use e.g. \"10 minutes\" / \"1 hour\")"
                  end
            CATimedelta::Element.new(res.count, res.base)
          end
        end
      unless element
        raise ArgumentError,
              "#{label} a time key needs a duration such as \"10 minutes\" " \
              "or a CATimedelta value (got #{width.inspect})"
      end
      if element.value < 0
        raise ArgumentError, "#{label} is a duration not below 0 (got #{width.inspect})"
      end
      element
    end
  end
end

# ----------------------------------------------------------------------------
#
#  CAFixlenString high-level construction surface.
#
#  CAFixlenString itself (the string interpretation of CA_FIXLEN storage) lives
#  in ext/ca_obj_string.c.  This file provides the ergonomic builder that packs
#  Ruby Strings into a fixed-width CA_FIXLEN entity and wraps it via
#  CAFixlenString.wrap.
#
# ----------------------------------------------------------------------------

class CArray

  # Build a CAFixlenString (fixed-width String array over CA_FIXLEN storage).
  #
  #   CArray.fixlen_string(["ab", "cde"], bytes: 4)   # explicit slot width
  #   CArray.fixlen_string(["ab", "cde"])             # width = max bytesize
  #   CArray.fixlen_string([a, nil, b], bytes: 8)     # nil → masked element
  #
  # The bounded slot width is the storage seam CAFixlenString exposes.
  # `truncate:` controls what happens when
  # a value exceeds `bytes` (only reachable when `bytes` is given explicitly;
  # the auto width can never overflow):
  #
  #   :error   (default) raise ArgumentError on overflow — loud data loss
  #   :silent  let the native fixlen store keep the leading `bytes` bytes
  #
  # The overflow policy lives at this construction surface, not at per-cell
  # `fix[i] = v` (which always truncates silently via the native fixlen store).
  # A CArray source is normalised through a String Face
  # ({CArray.string_face_of}): a raw CA_FIXLEN of matching width wraps
  # zero-copy, other string-bearing arrays materialise, numeric is rejected.
  # @overload fixlen_string(values, bytes: nil, truncate: :error)
  #   @param values [Array<String, nil>] source values.
  #   @param bytes [Integer, nil] slot width; defaults to the max bytesize.
  #   @param truncate [Symbol] `:error` or `:silent`.
  #   @return [CAFixlenString]
  # @overload fixlen_string(ca, bytes: nil, truncate: :error)
  #   @param ca [CArray] a String Face, CA_OBJECT, or raw CA_FIXLEN array.
  #   @return [CAFixlenString]
  #   @raise [CArray::DataTypeError] if `ca` is numeric / boolean.
  # @overload fixlen_string(n, bytes: nil, truncate: :error) { |i| ... }
  #   @param n [Integer] element count.
  #   @param bytes [Integer, nil] slot width; defaults to the max bytesize.
  #   @param truncate [Symbol] `:error` or `:silent`.
  #   @return [CAFixlenString]
  def self.fixlen_string (arg, bytes: nil, truncate: :error, &block)
    if arg.is_a?(CArray)
      return string_face_of(arg).to_fixlen_string(bytes: bytes, truncate: truncate)
    end
    unless [:error, :silent].include?(truncate)
      raise ArgumentError, "truncate: must be :error or :silent (got #{truncate.inspect})"
    end
    if block
      n = Integer(arg)
      if block.arity == 0
        v = block.call
        values = Array.new(n) { v }
      else
        values = Array.new(n) { |i| block.call(i) }
      end
    else
      values = arg.to_a
    end

    width = bytes || values.compact.map { |s| s.to_s.bytesize }.max || 1
    width = 1 if width < 1

    if truncate == :error
      values.each_with_index do |s, i|
        next if s.nil?
        b = s.to_s.bytesize
        if b > width
          raise ArgumentError,
                "CArray.fixlen_string: value at #{i} is #{b} bytes, exceeds slot width #{width} " \
                "(use truncate: :silent to keep the leading bytes)"
        end
      end
    end

    entity = CArray.new(CA_FIXLEN, [values.size], :bytes => width)
    values.each_with_index do |s, i|
      entity[i] = s.nil? ? UNDEF : s.to_s
    end
    CAFixlenString.wrap(entity)
  end

end

# Mutable fixed-width String Face: L1 ops + in-place variants.  In-place
# transforms re-store through the native fixlen path (silent truncate).
class CAFixlenString
  include CArray::StringOperationMixin
  include CArray::StringOperationMixin::Mutable
end

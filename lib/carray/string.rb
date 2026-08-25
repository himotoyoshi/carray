# ----------------------------------------------------------------------------
#
#  CAString high-level construction surface.
#
#  CAString itself (the identity Face over CA_OBJECT storage) lives in
#  ext/ca_obj_string.c.  This file provides the ergonomic builder that packs
#  Ruby Strings into a CA_OBJECT entity and wraps it via CAString.wrap.
#
# ----------------------------------------------------------------------------

class CArray

  # Build a CAString (mutable String array over object storage) from Ruby data.
  #
  #     CArray.string(["alpha", "", "gamma"])   # 1-D from Array
  #     CArray.string(3) { |i| "item#{i}" }     # block form
  #     CArray.string([a, nil, b])              # nil → masked element
  #     CArray.string(other_ca)                 # from a String Face / object / raw fixlen
  #
  # `nil` entries become masked cells; "" (empty) is a valid distinct value.
  # A CArray source is normalised through a String Face ({CArray.string_face_of}):
  # a String Face converts, CA_OBJECT storage wraps, a raw CA_FIXLEN reads as
  # NUL-stripped strings; a numeric / boolean array is rejected (stringify with
  # {#format} / {CArray.format}).
  # @overload string(values)
  #   Returns a {CAString} wrapping a CA_OBJECT entity of the given values.
  #   @param values [Array<String, nil>] source values.
  #   @return [CAString]
  # @overload string(ca)
  #   Returns a {CAString} of the string-bearing CArray `ca`.
  #   @param ca [CArray] a String Face, CA_OBJECT, or raw CA_FIXLEN array.
  #   @return [CAString]
  #   @raise [CArray::DataTypeError] if `ca` is numeric / boolean.
  # @overload string(n) { |i| ... }
  #   Returns an `n`-element {CAString} filled by the block, following the
  #   arity-0 broadcast convention.
  #   @param n [Integer] element count.
  #   @yieldparam i [Integer] cell index.
  #   @yieldreturn [String, nil] value for cell `i`.
  #   @return [CAString]
  def self.string (arg, &block)
    return string_face_of(arg).to_string if arg.is_a?(CArray)

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

    entity = CArray.object(values.size)
    values.each_with_index do |s, i|
      entity[i] = s.nil? ? UNDEF : s
    end
    CAString.wrap(entity)
  end

end

# Mutable object-backed String Face: L1 ops + in-place variants.
class CAString
  include CArray::StringOperationMixin
  include CArray::StringOperationMixin::Mutable
end

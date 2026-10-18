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
  # A cell of a CAString is a String.  In the Array and block forms `nil`
  # becomes a masked cell; "" (empty) is a valid distinct value.  Any other
  # value (a Symbol, a number, a nested Array) is refused: the values are one
  # cell each, so a CAString of more than one dimension is built from an
  # object array (`CArray.string(CA_OBJECT(nested))`).
  # A CArray source is normalised through a String Face: a String Face
  # converts, CA_OBJECT storage wraps zero-copy (every cell that is not
  # masked must be a String, `nil` included: mask it instead), a raw
  # CA_FIXLEN reads as NUL-stripped strings; a numeric / boolean array is
  # rejected (stringify with {#format} / {CArray.format}).
  # @overload string(values)
  #   Returns a {CAString} wrapping a CA_OBJECT entity of the given values.
  #   @param values [Array<String, nil>] source values.
  #   @return [CAString]
  #   @raise [TypeError] if a value is neither a String nor `nil`.
  # @overload string(ca)
  #   Returns a {CAString} of the string-bearing CArray `ca`.
  #   @param ca [CArray] a String Face, CA_OBJECT, or raw CA_FIXLEN array.
  #   @return [CAString]
  #   @raise [CArray::DataTypeError] if `ca` is numeric / boolean.
  #   @raise [TypeError] if a cell of an object array that is not masked is
  #     not a String.
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
      if s.is_a?(Array)
        raise TypeError,
              "CArray.string: value #{i} is an Array; a CAString cell is a " \
              "String (for a CAString of another shape, give " \
              "CArray.string an object array: CArray.string(CA_OBJECT(values)))"
      end
      entity[i] = s.nil? ? UNDEF : s
    end
    CAString.wrap(entity)
  end

end

# Mutable object-backed String Face: L1 ops + in-place variants.
class CAString
  include CArray::StringOperationMixin
  include CArray::StringOperationMixin::Mutable

  # The String operators and the picks by order run on the object storage,
  # cell by cell, as on any object array.  A String's +, * and % give a
  # String (or raise), and a pick gives one of the operands, so the result
  # is text and comes back as a CAString, as the bang forms (add!, mul!)
  # keep it.  A lazy operand is computed here.

  # Per-cell `String#+`.
  # @return [CAString] shape and mask carried.
  def + (other) ; as_text(super) ; end
  # Per-cell `String#+` (the word form of {#+}).
  # @return [CAString]
  def add (other) ; as_text(super) ; end
  # Per-cell `String#*`.
  # @return [CAString] shape and mask carried.
  def * (other) ; as_text(super) ; end
  # Per-cell `String#*` (the word form of {#*}).
  # @return [CAString]
  def mul (other) ; as_text(super) ; end
  # Per-cell `String#%` (format).
  # @return [CAString] shape and mask carried.
  def % (other) ; as_text(super) ; end
  # Per-cell `String#%` (the word form of {#%}).
  # @return [CAString]
  def mod (other) ; as_text(super) ; end
  # The later String of each cell and `other`, cell by cell.
  # @return [CAString]
  def pmax (other) ; as_text(super) ; end
  # The earlier String of each cell and `other`, cell by cell.
  # @return [CAString]
  def pmin (other) ; as_text(super) ; end
  # Another name of {#pmax} (a String has no NaN to let win).
  # @return [CAString]
  def maximum (other) ; as_text(super) ; end
  # Another name of {#pmin}.
  # @return [CAString]
  def minimum (other) ; as_text(super) ; end
  # Another name of {#pmax}.
  # @return [CAString]
  def fmax (other) ; as_text(super) ; end
  # Another name of {#pmin}.
  # @return [CAString]
  def fmin (other) ; as_text(super) ; end

  private def as_text (result)
    result = result.copy if result.lazy_view?
    CAString.wrap(result)
  end
end

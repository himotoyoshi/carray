# ----------------------------------------------------------------------------
#
#  CAFixlenString high-level construction surface.
#
#  CAFixlenString itself (the string interpretation of CA_FIXLEN storage) lives
#  in ext/ca_obj_fixlen_string.c.  This file provides the ergonomic builder that packs
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
  #   @param bytes [Integer, nil] slot width, 1 or more; defaults to the
  #     max bytesize (1 when every string is empty).
  #   @param truncate [Symbol] `:error` or `:silent`.
  #   @return [CAFixlenString]
  #   @raise [ArgumentError] when `bytes` is given below 1.
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
      return string_face_of(arg, "CArray.fixlen_string").to_fixlen_string(bytes: bytes, truncate: truncate)
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

    unless bytes.nil? || (bytes.is_a?(Integer) && bytes >= 1)
      raise ArgumentError, "CArray.fixlen_string: invalid bytes: #{bytes.inspect} (a cell needs bytes: of 1 or more)"
    end
    width = bytes || values.compact.map { |s| s.to_s.bytesize }.max || 1
    width = 1 if width < 1   # every string empty: the narrowest cell

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
    CAFixlenString.wrap(entity, encoding: CAFixlenString.__send__(:encoding_of_strings, values))
  end

end

# Mutable fixed-width String Face: L1 ops + in-place variants.  In-place
# transforms re-store through the native fixlen path (silent truncate).
class CAFixlenString

  # The greater String of each cell and `other`, cell by cell: `other` is a
  # CAFixlenString of the same shape or one String.  The result is as wide as
  # the wider of the two.
  # @return [CAFixlenString]
  def pmax (other)
    refuse_unordered_operands(__callee__, other)
    pick_by_order(other) { |a, b| a.lt(b) }
  end

  # The lesser String of each cell and `other`; see {#pmax}.
  # @return [CAFixlenString]
  def pmin (other)
    refuse_unordered_operands(__callee__, other)
    pick_by_order(other) { |a, b| a.gt(b) }
  end

  # A String has no NaN to let win, so these are other names of pmax / pmin.
  alias_method :maximum, :pmax
  alias_method :minimum, :pmin
  alias_method :fmax, :pmax
  alias_method :fmin, :pmin

  # @overload min_addr(axis: nil)
  #   @return [Integer, CArray] the flat address of the smallest String.
  def min_addr (*args, **kw)
    to_string.min_addr(*args, **kw)
  end

  # @overload max_addr(axis: nil)
  #   @return [Integer, CArray] the flat address of the largest String.
  def max_addr (*args, **kw)
    to_string.max_addr(*args, **kw)
  end

  # A value that is no String is in no cell, and the kernels below take only
  # bytes: these ask the Strings, which answer it as any other value.
  CArray.send(:define_named_methods, self,
              [:eq, :ne, :count, :search, :search_addr, :is_in, :union, :difference, :intersection],
              :through_strings_unless_text, super_block: true)

  private def through_strings_unless_text (op, args, kw)
    v = args[0]
    return yield(*args, **kw) if args.empty? || v.is_a?(String) || v.is_a?(CArray) ||
                                 v.is_a?(Array) || UNDEF.equal?(v)
    to_string.public_send(op, *args, **kw)
  end

  # `other` where the block says self's cell loses to it, else self's cell.
  # Another array of Strings (a CAString, a CAConstString, an object array)
  # is taken as fixed-length strings, so the result is one.
  private def pick_by_order (other)
    return copy.tap { |out| out[] = UNDEF } if UNDEF.equal?(other)
    if other.is_a?(CArray) && !other.is_a?(CAFixlenString)
      other = CArray.string(other) if other.data_type == CA_OBJECT && !other.face?
      other = other.to_fixlen_string if other.respond_to?(:to_fixlen_string)
    end
    yield(self, other).then_else(other, self)
  end

  # Both branches of a selection at the width of the wider one.
  private def branches_in_common (x, y)
    width = [x, y].map { |v|
      case v
      when CArray then v.bytes
      when String then v.bytesize
      else 1
      end
    }.max
    [x, y].map { |v|
      v.is_a?(CAFixlenString) && !v.scalar? ? v.to_fixlen_string(bytes: width) : v
    }
  end

  # The encoding a column of these strings holds its text in: that of the
  # strings beyond ASCII, UTF-8 if none is, and BINARY if they disagree,
  # since the column cannot read them all back.
  private_class_method def self.encoding_of_strings (values)
    text = values.compact.map(&:to_s).reject(&:ascii_only?).map(&:encoding).uniq
    text.size > 1 ? Encoding::BINARY : (text.first || Encoding::UTF_8)
  end

  # inspect's name for the array: the class and the cell width, which is the
  # longest string a cell holds.
  private def inspect_label
    "#{self.class}[#{bytes}]"
  end

  include CArray::StringOperationMixin
  include CArray::StringOperationMixin::Mutable

  # ---- order family beyond the fixlen kernels --------------------------
  #
  # min / max / sort run on the cells' bytes.  The members those kernels do
  # not cover answer here: minmax as the pair of them, and the running
  # extremes through the strings ({#to_string}), as CAString answers them,
  # written back at this width.

  # @return [Array(String, String), Array(CAFixlenString, CAFixlenString)]
  #   `[min, max]`, with the keywords of {CArray#min} / {CArray#max}.
  def minmax (*args, **kw)
    [min(*args, **kw), max(*args, **kw)]
  end

  # @return [CAFixlenString] the running maximum, as {CArray#cummax}.
  def cummax (*args, **kw)
    to_string.cummax(*args, **kw).to_fixlen_string(bytes: bytes)
  end

  # @return [CAFixlenString] the running minimum, as {CArray#cummin}.
  def cummin (*args, **kw)
    to_string.cummin(*args, **kw).to_fixlen_string(bytes: bytes)
  end

  # A String has no distance, so there is no nearest one; refused in the
  # words CAString uses.
  def search_nearest (*args, **kw)
    to_string.search_nearest(*args, **kw)
  end

  # @see #search_nearest
  def search_nearest_addr (*args, **kw)
    to_string.search_nearest_addr(*args, **kw)
  end
end

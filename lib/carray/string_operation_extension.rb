#  Shared String-operation surface for the String Faces: the
#  CArray::StringOperationMixin (included by CAString / CAFixlenString /
#  CAConstString).

class CArray

  # String-array operations, mixed into the String Faces (CAConstString /
  # CAFixlenString / CAString) — not into CArray itself, so numeric arrays
  # carry no string methods.
  #
  # Dispatch tiers:
  #   L1 (here)  generic per-cell implementation.  Reads each cell through the
  #              Face's scalar fetch (so CAConstString / CAFixlenString / CAString
  #              all yield a proper Ruby String), applies the operation, and
  #              builds a shape+mask-preserving output.
  #   L3         a Face may override any method with a byte-level C-native
  #              version (CAConstString already does for the byte predicates /
  #              search / comparison).  Ruby method resolution puts the Face's
  #              own method ahead of this module, so an override simply wins;
  #              anything not overridden falls back to L1.
  #
  # Output by return category (Option alpha):
  #   String result   -> CAString (mutable object-backed String array).  Chain
  #                      #to_const_string / #to_fixlen_string to re-compact.
  #   Integer result  -> :int CArray
  #   Boolean result  -> :boolean CArray
  module StringOperationMixin

    # Per-cell map through the Face's scalar fetch.  `dtype` nil returns a
    # CAString (string results); an explicit dtype returns a plain typed array
    # (integer / boolean results).  Shape and mask are carried.
    def string_map (dtype = nil) # :nodoc:
      out = dtype ? template(dtype) : CArray.object(*shape)
      if has_mask?
        m = is_masked
        elements.times { |i| out[i] = (m[i] ? UNDEF : yield(self[i])) }
      else
        elements.times { |i| out[i] = yield(self[i]) }
      end
      dtype ? out : CAString.wrap(out)
    end
    private :string_map

    # ---- transforms (String result -> CAString) --------------------------

    # Per-cell `String#upcase`.
    # @return [CAString] shape and mask of `self` preserved.
    def upcase ()      ; string_map { |s| s.upcase } ; end
    # Per-cell `String#downcase`.
    # @return [CAString] shape and mask of `self` preserved.
    def downcase ()    ; string_map { |s| s.downcase } ; end
    # Per-cell `String#capitalize`.
    # @return [CAString] shape and mask of `self` preserved.
    def capitalize ()  ; string_map { |s| s.capitalize } ; end
    # Per-cell `String#swapcase`.
    # @return [CAString] shape and mask of `self` preserved.
    def swapcase ()    ; string_map { |s| s.swapcase } ; end
    # Per-cell `String#strip`.
    # @return [CAString] shape and mask of `self` preserved.
    def strip ()       ; string_map { |s| s.strip } ; end
    # Per-cell `String#lstrip`.
    # @return [CAString] shape and mask of `self` preserved.
    def lstrip ()      ; string_map { |s| s.lstrip } ; end
    # Per-cell `String#rstrip`.
    # @return [CAString] shape and mask of `self` preserved.
    def rstrip ()      ; string_map { |s| s.rstrip } ; end
    # Per-cell `String#chomp`.
    # @return [CAString] shape and mask of `self` preserved.
    def chomp (*a)     ; string_map { |s| s.chomp(*a) } ; end
    # Per-cell `String#gsub`.
    # @return [CAString] shape and mask of `self` preserved.
    def gsub (*a, &b)  ; string_map { |s| s.gsub(*a, &b) } ; end
    # Per-cell `String#delete_prefix`.
    # @return [CAString] shape and mask of `self` preserved.
    def delete_prefix (p) ; string_map { |s| s.delete_prefix(p) } ; end
    # Per-cell `String#delete_suffix`.
    # @return [CAString] shape and mask of `self` preserved.
    def delete_suffix (p) ; string_map { |s| s.delete_suffix(p) } ; end
    # Per-cell `String#center`.
    # @return [CAString] shape and mask of `self` preserved.
    def center (*a)    ; string_map { |s| s.center(*a) } ; end
    # Per-cell `String#ljust`.
    # @return [CAString] shape and mask of `self` preserved.
    def ljust (*a)     ; string_map { |s| s.ljust(*a) } ; end
    # Per-cell `String#rjust`.
    # @return [CAString] shape and mask of `self` preserved.
    def rjust (*a)     ; string_map { |s| s.rjust(*a) } ; end
    # Per-cell `String#encode`.
    # @return [CAString] shape and mask of `self` preserved.
    def encode (*a)    ; string_map { |s| s.encode(*a) } ; end
    # Per-cell `String#force_encoding`.
    # @return [CAString] shape and mask of `self` preserved.
    def force_encoding (e) ; string_map { |s| s.force_encoding(e) } ; end
    # Per-cell `String#scrub`.
    # @return [CAString] shape and mask of `self` preserved.
    def scrub ()       ; string_map { |s| s.scrub } ; end

    # ---- predicates (Boolean result -> :boolean) -------------------------
    # start_with? / end_with? / include? are byte-level and free of collisions
    # with CArray; CAConstString overrides them with C-native versions (L3).

    # Per-cell `String#start_with?`.
    # @return [CArray] boolean, shape and mask of `self` preserved.
    def start_with? (*a) ; string_map(:boolean) { |s| s.start_with?(*a) } ; end
    # Per-cell `String#end_with?`.
    # @return [CArray] boolean, shape and mask of `self` preserved.
    def end_with? (*a)   ; string_map(:boolean) { |s| s.end_with?(*a) } ; end
    # Per-cell `String#include?`.
    # @return [CArray] boolean, shape and mask of `self` preserved.
    def include? (sub)   ; string_map(:boolean) { |s| s.include?(sub) } ; end
    # Per-cell `String#match?`.
    # @return [CArray] boolean, shape and mask of `self` preserved.
    def match? (re)      ; string_map(:boolean) { |s| s.match?(re) } ; end

    # ---- length / position (Integer result -> :int) ----------------------
    # `str_len` keeps the prefix because bare #length / #size mean element
    # count on a CArray; `str_index` because bare #index is an array method.
    # `bytesize` / `rindex` have no array-level collision, so they stay bare.

    # Per-cell `String#length`.
    # @return [CArray] `:int`, shape and mask of `self` preserved.
    def str_len ()     ; string_map(:int) { |s| s.length } ; end
    # Per-cell `String#bytesize`.
    # @return [CArray] `:int`, shape and mask of `self` preserved.
    def bytesize ()    ; string_map(:int) { |s| s.bytesize } ; end
    # Per-cell `String#index`.
    # @return [CArray] `:int`, shape and mask of `self` preserved.
    def str_index (*a) ; string_map(:int) { |s| s.index(*a) } ; end
    # Per-cell `String#rindex`.
    # @return [CArray] `:int`, shape and mask of `self` preserved.
    def rindex (*a)    ; string_map(:int) { |s| s.rindex(*a) } ; end

    # ---- numeric parse (Integer / Float result) --------------------------

    # Per-cell `String#to_i`.
    # @return [CArray] `:int`, shape and mask of `self` preserved.
    def to_i ()        ; string_map(:int)     { |s| s.to_i } ; end
    # Per-cell `String#to_f`.
    # @return [CArray] `float64`, shape and mask of `self` preserved.
    def to_f ()        ; string_map(:float64) { |s| s.to_f } ; end

    # ---- membership ------------------------------------------------------

    # @overload in?(*strings)
    #   Returns a boolean CArray marking every cell whose value equals one of
    #   `strings` (set membership).  The string counterpart of `#match?` for
    #   regexps: both mark all matching cells.
    #   @param strings [Array<String>]
    #   @return [CArray]
    def in? (*strings)
      string_map(:boolean) { |s| strings.include?(s) }
    end

    # @overload extract(regexp, replace = '\0')
    #   Returns a CArray whose cells are each cell's first match of `regexp`
    #   transformed by `String#sub(regexp, replace)`; non-matching cells
    #   become `""`.
    #   @param regexp [Regexp]
    #   @param replace [String]
    #   @return [CAString]
    def extract (regexp, replace = '\0')
      string_map { |s| regexp.match(s) { |m| m[0].sub(regexp, replace) } || "" }
    end

    # --- inter-Face conversions (String Faces only) ----------------------
    # These live on the mixin, not on CArray, so numeric arrays carry no
    # string conversion (the same reason the string operations above are
    # Face-only).  Non-Face sources reach a Face through the CArray.string /
    # fixlen_string / const_string builders.  Each follows the to_ca
    # principle: self (zero-copy) when self is already the target Face
    # (compatibly), else materialise the string surface (shape + mask carried).

    # @return [CAString]
    def to_string
      return self if is_a?(CAString)
      entity = CArray.object(*shape)
      if has_mask?
        m = is_masked
        elements.times { |i| entity[i] = (m[i] ? UNDEF : self[i]) }
      else
        elements.times { |i| entity[i] = self[i] }
      end
      CAString.wrap(entity)
    end

    # @param bytes [Integer, nil] slot width; defaults to the max bytesize.
    # @param truncate [Symbol] :error or :silent (see {CArray.fixlen_string}).
    # @return [CAFixlenString]
    def to_fixlen_string (bytes: nil, truncate: :error)
      unless [:error, :silent].include?(truncate)
        raise ArgumentError, "truncate: must be :error or :silent (got #{truncate.inspect})"
      end
      return self if is_a?(CAFixlenString) && (bytes.nil? || bytes == self.bytes)

      if has_mask?
        m = is_masked
        values = Array.new(elements) { |i| m[i] ? nil : self[i].to_s }
      else
        values = Array.new(elements) { |i| self[i].to_s }
      end
      width = bytes || values.compact.map(&:bytesize).max || 1
      width = 1 if width < 1
      if truncate == :error
        values.each_with_index do |s, i|
          next if s.nil?
          if s.bytesize > width
            raise ArgumentError,
                  "to_fixlen_string: value at #{i} is #{s.bytesize} bytes, exceeds slot width #{width} " \
                  "(use truncate: :silent to keep the leading bytes)"
          end
        end
      end
      entity = CArray.new(CA_FIXLEN, shape, :bytes => width)
      values.each_with_index { |s, i| entity[i] = s.nil? ? UNDEF : s }
      CAFixlenString.wrap(entity)
    end

    # Self (zero-copy) when already a {CAConstString} of the same encoding;
    # otherwise materialises a compact column.
    # @param encoding [Encoding] column encoding.
    # @return [CAConstString]
    def to_const_string (encoding: Encoding::UTF_8)
      if is_a?(CAConstString) && encoding == self.encoding
        return self
      end
      if has_mask?
        m = is_masked
        values = Array.new(elements) { |i| m[i] ? nil : self[i] }
      else
        values = Array.new(elements) { |i| self[i] }
      end
      CArray.const_string(values, encoding: encoding)
    end

    # In-place transforms, mixed into the mutable Faces only (CAString /
    # CAFixlenString); CAConstString is read-only and does not include it.
    module Mutable
      # Writes per-cell `String#upcase` back into `self`.
      # @return [CAString] the computed values that were written.
      def upcase! ()     ; self[] = upcase ; end
      # Writes per-cell `String#downcase` back into `self`.
      # @return [CAString] the computed values that were written.
      def downcase! ()   ; self[] = downcase ; end
      # Writes per-cell `String#capitalize` back into `self`.
      # @return [CAString] the computed values that were written.
      def capitalize! () ; self[] = capitalize ; end
      # Writes per-cell `String#swapcase` back into `self`.
      # @return [CAString] the computed values that were written.
      def swapcase! ()   ; self[] = swapcase ; end
      # Writes per-cell `String#strip` back into `self`.
      # @return [CAString] the computed values that were written.
      def strip! ()      ; self[] = strip ; end
      # Writes per-cell `String#lstrip` back into `self`.
      # @return [CAString] the computed values that were written.
      def lstrip! ()     ; self[] = lstrip ; end
      # Writes per-cell `String#rstrip` back into `self`.
      # @return [CAString] the computed values that were written.
      def rstrip! ()     ; self[] = rstrip ; end
      # Writes per-cell `String#chomp` back into `self`.
      # @return [CAString] the computed values that were written.
      def chomp! (*a)    ; self[] = chomp(*a) ; end
      # Writes per-cell `String#gsub` back into `self`.
      # @return [CAString] the computed values that were written.
      def gsub! (*a, &b) ; self[] = gsub(*a, &b) ; end
    end

  end

  # Normalise a string-bearing CArray to a String Face, for the string
  # builders.  A String Face passes through; CA_OBJECT storage wraps as a
  # CAString (its cells are the Ruby Strings); a raw CA_FIXLEN array wraps as a
  # CAFixlenString, so its cells read as NUL-stripped strings.  A numeric /
  # boolean array has no string reading and is rejected -- stringify explicitly
  # with #format / CArray.format.  (This mirrors the numeric gate that rejects
  # numeric reductions on a String Face.)
  def self.string_face_of (ca)
    return ca if ca.is_a?(CArray::StringOperationMixin)
    case ca.data_type
    when :object then CAString.wrap(ca)
    when :fixlen then CAFixlenString.wrap(ca)
    else
      raise CArray::DataTypeError,
            "cannot build a string column from a #{ca.data_type} array " \
            "(use #format or CArray.format to stringify numbers)"
    end
  end
  private_class_method :string_face_of

end

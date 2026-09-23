# ----------------------------------------------------------------------------
#
#  carray/const_string.rb
#
#  CAConstString high-level construction + conversion surface.
#
#  CAConstString itself (the Face + tail buffer + fetch decode + numeric gate) lives
#  in ext/ca_obj_const_string.c.  This file provides the ergonomic builders that
#  pack Ruby Strings into the shared buffer + (start,end) pair entity, via the
#  CAConstString.__build__ C primitive.
#
#  Internal buffer format: a pure concatenation of the element bytes, with no
#  per-record length prefix (= the Arrow values buffer).  Each element carries
#  its own `(start, end)` byte range in the storage, so it is self-describing
#  and a gather / sort / select view over the pairs decodes correctly with no
#  buffer copy.
#
# ----------------------------------------------------------------------------

class CArray

  # Build a CAConstString (read-only variable-length string column) from Ruby data.
  #
  #     CArray.const_string(["alpha", "", "gamma"])       # 1-D from Array
  #     CArray.const_string(3) { |i| "item#{i}" }         # block form
  #     CArray.const_string([a, nil, b])                   # nil → masked element
  #
  # B1: "" (length 0) is a valid empty string, distinct from a masked element
  #     (nil → masked).  B2: element encoding must match :encoding (strict),
  #     pure-ASCII strings pass regardless (ASCII-compatible relaxation).
  #
  # Storage is one `(start, end)` byte-range pair per element over a
  # pure-concatenation buffer (Arrow string layout).  For a high-duplication
  # column (categorical labels), use {CACategorical} (= Arrow DictionaryArray)
  # instead — CAConstString stores every element's bytes, without dedup.
  # @overload const_string(values, encoding: Encoding::UTF_8)
  #   Returns a read-only {CAConstString} column packing each String's
  #   bytes into a shared buffer. `values` may be any Array (or
  #   Array-like) of Strings; `nil` entries are masked.
  #   @param values [Array<String, nil>] source values.
  #   @param encoding [Encoding] column encoding.
  #   @return [CAConstString]
  # @overload const_string(ca, encoding: Encoding::UTF_8)
  #   Builds from a string-bearing CArray (String Face / CA_OBJECT / raw
  #   CA_FIXLEN, the last read as NUL-stripped strings); always materialises.
  #   @param ca [CArray] source array.
  #   @return [CAConstString]
  #   @raise [CArray::DataTypeError] if `ca` is numeric / boolean.
  # @overload const_string(n, encoding: Encoding::UTF_8) { |i| ... }
  #   Returns an `n`-element {CAConstString} column filled by the
  #   block, following the arity-0 broadcast convention.
  #   @param n [Integer] element count.
  #   @yieldparam i [Integer] cell index.
  #   @yieldreturn [String, nil] value for cell `i`.
  #   @return [CAConstString]
  def self.const_string (arg, encoding: Encoding::UTF_8, &block)
    if arg.is_a?(CArray)
      return string_face_of(arg).to_const_string(encoding: encoding)
    end
    if block
      n = Integer(arg)
      # B5: follow CArray.<type>(n){ ... } arity-0 broadcast quirk for
      #     consistency — arity-0 block is evaluated once and broadcast.
      if block.arity == 0
        v = block.call
        values = Array.new(n) { v }
      else
        values = Array.new(n) { |i| block.call(i) }
      end
    else
      values = arg.to_a
    end

    # Arrow-style layout, built in one C pass: pure-concatenation buffer +
    # one (start,end) int64 pair per element, mask for nil.
    CAConstString.__build__(values, encoding)
  end

end

# Read-only column of variable-length Strings: every element's bytes are
# packed into one shared buffer, with a `(start, end)` byte-range pair per
# element (the Arrow string layout).
#
# Built through `CArray.const_string`.  For a column with heavy duplication
# (categorical labels) prefer {CACategorical}, which stores each distinct
# value once.
class CAConstString

  # Read-only String Face: L1 string operations only (no in-place Mutable).
  # Its C-native byte predicates / search / comparison (ext/ca_obj_const_string.c)
  # override the L1 generics where present.
  include CArray::StringOperationMixin

  # ---- ordering family ---------------------------------------------------
  #
  # A storage cell is a `(start, end)` byte range into the shared buffer, so
  # storage order is the order the strings were packed in, not the order they
  # compare in.  Without these overrides the family sorted the offsets: the
  # answers came back well-formed and wrong -- `%w[pear apple].sort_addr` gave
  # the identity, and `partition_copy` gave NUL bytes.
  #
  # Every member therefore reads the bytes.  The flat forms do it natively
  # (a byte-memcmp scan over the packed buffer, an order of magnitude faster
  # than decoding a Ruby String per cell), the per-axis forms through
  # {#to_string}, where a cell is the string and CArray's own kernels apply.
  # Arguments are forwarded verbatim, so `kind:` / `masked_position:` /
  # `keep_axis:` mean here what they mean on CArray.
  #
  # Anything whose cells are strings comes back a CAConstString, gathered
  # over the same buffer where it can be (sort / sort_copy) and rebuilt where
  # it cannot.  Indices, addresses and counts need no conversion.

  # @overload sort(axis: nil, kind: :quick, masked_position: :last)
  #   Returns a sorted {CAConstString} view, gathered over the same buffer
  #   and offsets.  With no `axis:` the array is flattened first, as
  #   `CArray#sort` does.
  #   @return [CAConstString]
  def sort (*args, **kw)
    addr = sort_addr(*args, **kw)
    kw[:axis].nil? ? self[addr.flatten] : self[addr]
  end

  # @overload sort_copy(axis: nil, kind: :quick, masked_position: :last)
  #   Returns an owned sorted {CAConstString}; the materialised counterpart
  #   to {#sort}.
  #   @return [CAConstString]
  def sort_copy (*args, **kw)
    sort(*args, **kw).copy
  end

  # @overload sort_addr(axis: nil, kind: :quick, masked_position: :last)
  #   Returns the view-flat addresses that index a sort by string order.
  #   @return [CArray] `:int64` addresses.
  def sort_addr (*args, **kw)
    # The native scan has no notion of an incomparable sentinel, so a masked
    # column goes the same way a per-axis one does.
    return __sort_addr_bytes__ if args.empty? && kw.empty? && ! has_mask?
    to_string.sort_addr(*args, **kw)
  end

  # @overload sort_index(axis: nil, kind: :quick, masked_position: :last)
  #   Returns the per-fiber indices that index a sort by string order.
  #   @return [CArray] `:int64` indices.
  def sort_index (*args, **kw)
    to_string.sort_index(*args, **kw)
  end

  # @overload rank_index(axis: nil)
  #   @return [CArray] each cell's rank in string order.
  def rank_index (*args, **kw)
    to_string.rank_index(*args, **kw)
  end

  # @overload order(*args)
  #   @return [CArray] the ordering of the cells by string order.
  def order (*args, **kw)
    to_string.order(*args, **kw)
  end

  # @overload min(axis: nil, keep_axis: false)
  #   Returns the byte-smallest string, skipping masked cells; UNDEF when
  #   every cell is masked or the array is empty.
  #   @return [String, CAConstString]
  def min (*args, **kw)
    return __min_bytes__ || UNDEF if args.empty? && kw.empty?
    const_string_lift(to_string.min(*args, **kw))
  end

  # @overload max(axis: nil, keep_axis: false)
  #   Byte-largest counterpart of {#min}.
  #   @return [String, CAConstString]
  def max (*args, **kw)
    return __max_bytes__ || UNDEF if args.empty? && kw.empty?
    const_string_lift(to_string.max(*args, **kw))
  end

  # @overload minmax(axis: nil, keep_axis: false)
  #   @return [Array] `[min, max]`.
  def minmax (*args, **kw)
    return [min, max] if args.empty? && kw.empty?
    to_string.minmax(*args, **kw).map { |r| const_string_lift(r) }
  end

  # @overload min_index(axis: nil)
  #   @return [Integer, CArray] where the byte-smallest string sits.
  def min_index (*args, **kw)
    to_string.min_index(*args, **kw)
  end

  # @overload max_index(axis: nil)
  #   @return [Integer, CArray] where the byte-largest string sits.
  def max_index (*args, **kw)
    to_string.max_index(*args, **kw)
  end

  # @overload partition_copy(kth, axis: nil)
  #   @return [CAConstString] partitioned about the `kth` string in order.
  def partition_copy (*args, **kw)
    const_string_lift(to_string.partition_copy(*args, **kw))
  end

  # @overload partition_index(kth, axis: nil)
  #   @return [CArray] the indices that partition about the `kth` string.
  def partition_index (*args, **kw)
    to_string.partition_index(*args, **kw)
  end

  # CAConstString is the one Face with three separate entities -- storage
  # (int64 offset), surface (fixlen), and the length-prefixed buffer -- so it
  # has no byte-compatible blank form (other Faces have surface == storage or
  # a struct tail, which the core template lift handles).  A same-class
  # template would be an unusable shell, so override it: with an explicit type
  # defer to the generic (plain) path; with no type return a plain same-shape
  # `object` array (a fillable string container), honouring a block.
  # @overload template(type = nil, **opts)
  #   @return [CArray]
  def template (*args, &block)
    return super unless args.empty?    # a type was given: generic plain path
    out = CArray.object(*shape)
    if block
      if block.arity == 0
        out[] = block.call
      else
        out.map_with_index! { |_, *idx| block.call(*idx) }
      end
    end
    out
  end

  # ---- value-hash discovery family --------------------------------------
  #
  # A storage cell is a `(start, end)` byte range into the shared buffer, so
  # storage equality is NOT string equality: "ab" appearing twice occupies two
  # distinct ranges.  The family's Face gate only descends a Face whose storage
  # equality *is* its surface equality (docs/authoring/FaceOrderingSearch.md
  # §5.0), and CAConstString is the Face it deliberately excludes -- without
  # these overrides `%w[ab cd ab ef].nunique` answered 4.
  #
  # So the family runs on {#to_string}, where a cell *is* the string, and value
  # outputs come back as a CAConstString.  Counts, booleans and addresses need
  # no conversion.

  # @overload unique(sort: false)
  #   @return [CAConstString] the distinct strings.
  def unique (sort: false)
    const_string_lift(to_string.unique(sort: sort))
  end

  # @overload value_counts(sort: false)
  #   @return [Array(CAConstString, CArray)] `[values, counts]`.
  def value_counts (sort: false)
    values, counts = to_string.value_counts(sort: sort)
    [const_string_lift(values), counts]
  end

  # @overload nunique(axis: nil, keep_axis: false)
  #   @return [Integer, CArray] the number of distinct strings.
  def nunique (axis: nil, keep_axis: false)
    to_string.nunique(axis: axis, keep_axis: keep_axis)
  end

  # @overload mode(axis: nil)
  #   @return [CAConstString, Array] the most frequent string(s).
  def mode (axis: nil)
    r = to_string.mode(axis: axis)
    r.is_a?(Array) ? r.map { |c| const_string_lift(c) } : const_string_lift(r)
  end

  # @overload is_mode(axis: nil)
  #   @return [CArray] boolean, true where the cell holds a modal string.
  def is_mode (axis: nil)
    to_string.is_mode(axis: axis)
  end

  # @overload mask_duplicates(axis: nil)
  #   @return [CAConstString] a copy with every repeat occurrence masked.
  def mask_duplicates (axis: nil)
    const_string_lift(to_string.mask_duplicates(axis: axis))
  end

  # @overload is_in(values)
  #   @return [CArray] boolean, true where the cell's string is in `values`.
  def is_in (values)
    to_string.is_in(string_operand(values))
  end

  # @overload intersection(other, sort: false)
  #   @return [CAConstString] the distinct strings present in both.
  def intersection (other, sort: false)
    const_string_lift(to_string.intersection(string_operand(other), sort: sort))
  end

  # @overload difference(other, sort: false)
  #   @return [CAConstString] the distinct strings only `self` has.
  def difference (other, sort: false)
    const_string_lift(to_string.difference(string_operand(other), sort: sort))
  end

  # @overload union(other, sort: false)
  #   @return [CAConstString] the distinct strings of either side.
  def union (other, sort: false)
    const_string_lift(to_string.union(string_operand(other), sort: sort))
  end

  # @overload locate_addr(ref)
  #   @return [CArray] for each cell, its address in `ref` (UNDEF when absent).
  def locate_addr (ref)
    to_string.locate_addr(string_operand(ref))
  end

  # @overload categorize(labels: nil, sort_labels: false)
  #   @return [CACategorical] categories keyed on the strings.
  def categorize (labels: nil, sort_labels: false)
    to_string.categorize(labels: labels, sort_labels: sort_labels)
  end

  # A CAConstString operand has to be decoded too; anything else (a CAString,
  # an object array, an Array) already compares as strings.
  private def string_operand (other)
    other.is_a?(CAConstString) ? other.to_string : other
  end

  # Pack a string-bearing result back into a column of this one's encoding.
  # The encoding has to be carried: the builder checks each element against
  # the column's, so a Shift_JIS column rebuilt as the UTF-8 default raised
  # rather than coming back.
  private def const_string_lift (x)
    x.is_a?(CArray) ? CArray.const_string(x, encoding: encoding) : x
  end

end

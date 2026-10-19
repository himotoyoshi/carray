# ----------------------------------------------------------------------------
#
#  carray/categorical.rb
#
#  CACategorical — a categorical data type: dense integer codes (the storage) plus
#  a label vocabulary. Structurally the same as a pandas Categorical or an
#  Arrow dictionary: each element is an index into a small set of categories.
#
#  Implemented as a READONLY NonNumeric Face (see docs/CAFace.md) over
#  the codes array:
#
#    - storage (parent) = the integer codes
#    - surface          = CA_FIXLEN, so raw numeric kernels are gated off
#                         (`cat + 1` raises — arithmetic on category codes is
#                         nonsense). The meaningful operations come back for
#                         free on the codes parent: `cat.codes.bincount`
#                         (per-category counts), `cat.codes.count(code)`, etc.
#    - per-cell access  = decode the code into its label (`cat[i]` -> category)
#
#  Exclusion (missing / out-of-vocabulary) is encoded two ways at once. Both
#  are written when the categorical is built — categorize produces them, and
#  from_codes normalises whatever it receives into them — and the Face is
#  READONLY afterwards, so they stay in step. Both are needed because they have
#  different readers: the axis-group kernel classifies on the code byte, the
#  materialising paths classify on the mask.
#
#    - the cell is MASKED                  -> CArray-native idiom: `cat[i]` is
#                                             UNDEF, `is_masked` / mask-aware
#                                             reductions / category_sizes all work
#    - the cell STORES the all-ones value  -> the type-max sentinel, which is
#                                             signed -1 byte-for-byte. The
#                                             axis-group kernel skips it by its
#                                             [0, k) range check (no kernel
#                                             change); the pandas / Arrow bridge
#                                             reads it as -1 by byte-reinterpret
#                                             (zero-copy, no conversion)
#
#  Because the codes ARE the storage parent, every view-creating operation
#  (slice / reshape / transpose / mask / …) carries the codes along the view
#  chain automatically; only the label vocabulary is carried via copy_state.
#
#  Construction:
#    keys.categorize                  # discover levels (first-appearance order)
#    keys.categorize(labels: set)     # fixed vocabulary; off-set keys excluded
#    CACategorical.from_codes(c, lab) # wrap already-dense codes + labels
#                                     # (= the pandas / Arrow import receiver)
#
# ----------------------------------------------------------------------------

require "carray"
require "carray/methods/is_in"   # refuse_range_set, for the set-valued verbs

# Categorical column: dense integer codes plus a label vocabulary, so each
# element is an index into a small set of categories.  Structurally the same
# idea as a pandas Categorical or an Arrow dictionary array.
#
# Implemented as a read-only non-numeric Face over the codes array — the
# storage is the integer codes, while the surface is `CA_FIXLEN` so numeric
# kernels are gated off (`cat + 1` raises; arithmetic on category codes is
# not meaningful).
class CACategorical < CAObject

  # raw-byte unpack format per storage (codes) data_type, native endian.
  # The FIXLEN surface delivers a per-cell fetch as an N-byte String; this
  # decodes it back into the integer code.
  UNPACK_FORMAT = {
    CA_INT8  => "c", CA_UINT8  => "C",
    CA_INT16 => "s", CA_UINT16 => "S",
    CA_INT32 => "l", CA_UINT32 => "L",
    CA_INT64 => "q", CA_UINT64 => "Q",
  }.freeze
  Ractor.make_shareable(UNPACK_FORMAT)

  # The exclusion sentinel per codes data_type: the all-ones bit pattern, read
  # as type-max for an unsigned data type and as -1 for a signed one. Either way it
  # is out of every valid [0, k) range and byte-identical to a pandas / Arrow
  # missing code.
  SENTINEL = {
    CA_UINT8  => 0xFF,               CA_INT8  => -1,
    CA_UINT16 => 0xFFFF,             CA_INT16 => -1,
    CA_UINT32 => 0xFFFFFFFF,         CA_INT32 => -1,
    CA_UINT64 => 0xFFFFFFFFFFFFFFFF, CA_INT64 => -1,
  }.freeze

  # The largest vocabulary each codes data type can carry: every valid code in
  # 0...k has to be representable AND distinct from the exclusion sentinel.  An
  # unsigned type spends its top value on the sentinel; a signed one spends -1,
  # which was never a valid index, so a signed type carries one more label than
  # the unsigned type of the same width.  categorize picks a width by this rule
  # when it builds codes; from_codes has to check it when it receives them.
  MAX_LABELS = {
    CA_UINT8  => 0xFF,               CA_INT8  => 0x80,
    CA_UINT16 => 0xFFFF,             CA_INT16 => 0x8000,
    CA_UINT32 => 0xFFFFFFFF,         CA_INT32 => 0x80000000,
    CA_UINT64 => 0xFFFFFFFFFFFFFFFF, CA_INT64 => 0x8000000000000000,
  }.freeze

  class << self
    # Wrap already-dense codes + labels with no discovery — the import receiver
    # for a pandas Categorical or an Arrow dictionary. from_codes takes
    # ownership of `codes`, which becomes the Face's storage parent: verbatim
    # when it is an entity that needs no rewriting, so a wrapped memory view
    # stays a view, and materialised when it is a view over an array the caller
    # still holds, since a view owns no bytes to take ownership of.
    #
    # This is the one door through which an already-built encoding enters, so
    # it validates rather than assumes, and it normalises before handing over:
    # a cell is excluded when it arrives masked OR holds the all-ones sentinel
    # (type-max for unsigned codes, -1 for signed — both the pandas / Arrow
    # missing code), and every excluded cell leaves here holding the sentinel
    # AND masked. Writing both matters because the two encodings have different
    # readers: the axis-group kernel classifies on the code byte, the
    # materialising paths classify on the mask. A categorical that carries only
    # one of them answers membership two ways, silently. An Arrow dictionary
    # carries its missingness in a validity bitmap with arbitrary code bytes —
    # frequently 0 — so arriving masked-only is the normal import, not an edge.
    #
    # #initialize marks the codes read-only, so this is also the last point at
    # which they can be written; a read-only argument is copied rather than
    # refused.
    # @overload from_codes(codes, labels)
    #   Returns a {CACategorical} wrapping already-dense integer
    #   `codes` with the given `labels`, without discovery. `codes`
    #   becomes the Face's storage parent, materialised first if it is
    #   a view. A cell that is masked or holds the type-max sentinel is
    #   excluded, and leaves as both.
    #   @param codes [CArray] integer code storage.
    #   @param labels [Array, CArray] category vocabulary indexed by
    #     code. Must be unique, and must fit the codes data type with
    #     the sentinel reserved.
    #   @return [CACategorical]
    #   @raise [ArgumentError] when `codes` is not an integer CArray,
    #     when `labels` holds duplicates or is too large for the codes
    #     data type, or when an unmasked code is outside `0...labels.size`
    #     and is not the sentinel.
    def from_codes(codes, labels)
      unless codes.is_a?(CArray) && SENTINEL.key?(codes.data_type)
        got = codes.is_a?(CArray) ? codes.data_type : codes.class
        raise ArgumentError, "from_codes: codes must be an integer CArray (got #{got})"
      end

      labels_arr = labels.respond_to?(:to_a) ? labels.to_a : Array(labels)
      if labels_arr.uniq.size != labels_arr.size
        raise ArgumentError, "from_codes: labels must be unique (got duplicates)"
      end
      k        = labels_arr.size
      sentinel = SENTINEL[codes.data_type]
      max      = MAX_LABELS[codes.data_type]
      if k > max
        raise ArgumentError,
              "from_codes: #{k} labels do not fit #{CArray.data_type_name(codes.data_type)} " \
              "codes, which carry at most #{max} (the top value is reserved as the " \
              "exclusion sentinel); widen the codes data type"
      end

      # Classify on the code bytes with the mask set aside (`.value`): a
      # comparison against a masked cell yields UNDEF, which would read as
      # "not excluded" and let the cell through carrying a valid-looking code.
      raw = codes.value
      if sentinel == -1                 # signed codes: -1 is the sentinel
        out = raw.lt(0)
        # Only test the upper bound when k is representable in the codes data
        # type. At the very top of the range (k == max) no value can reach k
        # anyway, and comparing against an unrepresentable literal would wrap
        # and flag every cell as out of range.
        out = out | raw.ge(k) if k <= max - 1
      else                              # unsigned codes: type-max is the sentinel
        out = raw.ge(k)                 # k <= max here, so always representable
      end
      masked   = codes.has_mask? ? codes.is_masked : nil
      excluded = masked ? (out | masked) : out
      # A masked cell may hold any byte at all — that is the CArray contract —
      # so it is never corrupt, only in need of normalising. An *unmasked* cell
      # holding an out-of-range code that is not the sentinel is neither a
      # category nor missingness; refuse it here, where the input is still in
      # the caller's hands, instead of letting it surface later as an IndexError
      # from the grouping plan or as a wrong label from a decode.
      corrupt = out & raw.ne(sentinel)
      corrupt = corrupt & masked.not if masked
      if corrupt.any
        bad = raw[corrupt].to_a.uniq.sort
        shown = bad.first(4).join(", ") + (bad.size > 4 ? ", ..." : "")
        raise ArgumentError,
              "from_codes: code#{bad.size == 1 ? "" : "s"} #{shown} outside " \
              "0...#{k} for #{k} label#{k == 1 ? "" : "s"} " \
              "(use #{sentinel} to exclude a cell, or mask it)"
      end

      # Take real ownership, then normalise so the byte reader and the mask
      # reader agree from here on.
      #
      # A view owns no bytes — its root does, and the caller still holds that
      # root. #initialize marks what it is given read-only, which would stop
      # `cat.codes[i] = x` but not `root[i] = x`, so the codes could still
      # change underneath a Face that is supposed to be immutable (and
      # underneath the grouping plan memoised against them). Marking the root
      # instead is worse: it would freeze bytes outside the window the caller
      # handed over. So a view is materialised. Read-only codes are copied for
      # the adjacent reason — the normalising writes need somewhere to land.
      #
      # An entity that needs no rewriting is adopted verbatim, which is what
      # keeps a wrapped memory view a view. That buffer's producer can still
      # write it; that is the borrowed-buffer bargain, and not something this
      # constructor can close.
      needs_mask = masked ? (excluded & masked.not).any : excluded.any
      needs_byte = (excluded & raw.ne(sentinel)).any
      if !codes.entity? || ((needs_mask || needs_byte) && codes.read_only?)
        codes = codes.copy
      end
      if needs_mask || needs_byte
        codes.value[excluded] = sentinel if needs_byte
        codes.mask = excluded
      end

      new(codes, labels_arr)
    end
  end

  # The rows' categorical for key columns of one length (CAFrame#group_by,
  # #is_duplicate, windows(on:, by:)).  Each column is categorized on its
  # own, so a component compares as a single key does (NaN is one value,
  # -0.0 is 0.0, a masked cell matches nothing); with several columns a
  # row's category is the tuple of its component codes, labelled by the
  # tuple of the component labels.  One masked component leaves the row in
  # no category, as a masked single key does.
  private_class_method def self.from_keys (cols)
    return cols.first.categorize if cols.size == 1
    nrow  = cols.first.elements
    cats  = cols.map(&:categorize)
    sizes = cats.map { |c| c.labels.size }
    tuple = if sizes.inject(1, :*) <= 2**62
              cats.drop(1).inject(cats[0].codes.int64) { |acc, c| acc * c.labels.size + c.codes.int64 }
            else
              codes = cats.map(&:codes)
              t = CArray.object(nrow) { |i| codes.map { |c| c[i] } }
              nrow.times { |i| t[i] = UNDEF if t[i].any? { |x| UNDEF.equal?(x) } }
              t
            end
    rows = tuple.categorize
    labels = rows.labels.map do |code|
      parts = code.is_a?(Array) ? code : sizes.reverse.map { |n| code, d = code.divmod(n); d }.reverse
      parts.each_with_index.map { |d, j| cats[j].labels[d] }
    end
    from_codes(rows.codes, labels)
  end

  # codes : integer CArray, the storage parent, already normalised by the
  #         caller (categorize builds it that way; from_codes rewrites what it
  #         receives). Excluded cells are both masked AND store the type-max
  #         sentinel value (= the all-ones bit pattern, which is signed -1
  #         byte-for-byte — the pandas / Arrow missing code). Marking the codes
  #         read-only below keeps the two in step from here on, so consumers may
  #         rely on either: the mask (CArray-native) or the sentinel
  #         (axis-group's out-of-range skip, zero-copy export).
  # labels: Array | CArray, the vocabulary; labels[code] = category.
  # @overload initialize(codes, labels)
  #   Allocates a READONLY {CACategorical} Face whose storage is
  #   `codes` and whose vocabulary is `labels`. The label list is
  #   copied and frozen so codes always index a stable vocabulary.
  #   @param codes [CArray] integer code storage.
  #   @param labels [Array, CArray] category vocabulary.
  def initialize(codes, labels)
    # Own a frozen copy of the vocabulary: the categorical is READONLY and its
    # codes index into labels, so the label list must not change under it. We
    # copy first so a caller's array is never frozen as a side effect; the
    # label objects themselves are left untouched (container-level freeze).
    @labels = (labels.respond_to?(:to_a) ? labels.to_a : Array(labels)).dup.freeze
    super(CA_FIXLEN, codes.shape,
          bytes:     codes.bytes,
          storage:   codes.data_type,
          parent:    codes,
          read_only: true,
          face:      true)
    # Mark the codes storage read-only so the READONLY guarantee holds at the
    # root, not just on the Face. Without this the Face is read_only but its
    # parent is writable, so `cat.codes[i] = x` silently mutates the categorical
    # (and any grouping cache derived from it). We set the CA_FLAG_READ_ONLY flag
    # rather than #freeze: freeze also freezes the Ruby object, which propagates
    # through views/Faces (a reshape of frozen codes is frozen) and would block
    # the grouping cache from memoising. The flag gives the same write protection
    # (mutations raise) while keeping the object non-frozen. One-way: it takes
    # ownership of `codes`, which from_codes has already validated, materialised
    # if it was a view, and normalised; a caller keeping a mutable entity of its
    # own must pass `.copy`.
    codes.set_read_only_flag
  end

  attr_reader :labels

  # The raw integer codes (= the storage parent). On a derived view this is
  # the correspondingly sliced/reshaped codes, since codes ride the chain.
  # Excluded cells are masked and store the type-max sentinel; the same array
  # serves the axis-group kernel (out-of-range skip) and the pandas / Arrow
  # bridge (byte-reinterpret to signed -1) with no conversion.
  # @overload codes
  #   Returns the raw integer code CArray backing `self`. Excluded
  #   cells are masked and store the type-max sentinel. The array is
  #   read-only — the categorical owns immutable codes, so
  #   `codes[i] = x` raises; use `codes.copy` for a mutable copy.
  #   @return [CArray]
  def codes
    parent
  end

  # Face hook: carry the vocabulary across lifted views (slice / reshape / …).
  # The codes ride along automatically as the Face's parent.
  def copy_state(src)
    @labels = src.labels
  end

  # Face hook: the homogeneity gate for multi-parent constructions
  # (CArray.promote_list / CArray.stack / anything that Face-lifts a list).
  # A code only means anything against the vocabulary it was assigned from, so
  # two categoricals may share one lifted Face only when they index the same
  # labels in the same code order.
  #
  # Same labels in a *different* code order is refused rather than re-coded,
  # for the same reason CATime refuses a unit mismatch it knows how to convert:
  # this is a predicate consulted after the parents are assembled, with no
  # channel to rewrite storage — and the codes are read-only by construction,
  # so agreeing would mean silently materialising fresh codes inside what the
  # caller asked for as a view. Build the shared vocabulary up front instead:
  # `keys.categorize(labels: shared)`.
  def face_state_compatible?(other)
    other.is_a?(CACategorical) && @labels == other.labels
  end

  # Face hook: decode a per-cell code into its category label, through the one
  # decode every code-to-label path shares (see #label_at).
  def storage_to_element(raw)
    code = raw.is_a?(String) ? raw.unpack1(UNPACK_FORMAT.fetch(parent.data_type)) : raw
    label_at(code)
  end

  # Face hook: a value written into a cell (a fill_value of shift and
  # window) is a label, and the cell holds its code.
  # @raise [ArgumentError] if the value is not one of the labels.
  def element_to_storage (value)
    code_for_fill(value)
  end

  # ---- category-space operations (by label, not code) -------------------
  #
  # The element value of a categorical IS its category, so these specialise
  # CArray's value operations into label space — the user never has to know
  # the integer code. The raw codes stay reachable via #codes for code-space
  # work (interop, ML features), but they are not the everyday surface.

  # @overload resize(*newdim, fill_value: UNDEF)
  #   Returns a categorical resized to `newdim` (see {CArray#resize}).
  #   The new cells are excluded (UNDEF) unless `fill_value` names one of
  #   the labels, since a zero code would read as the first label.
  #   @raise [ArgumentError] when `fill_value` is not a label.
  def resize (*newdim, fill_value: UNDEF)
    CACategorical.from_codes(codes.resize(*newdim, fill_value: code_for_fill(fill_value)),
                             labels)
  end

  # @overload insert_block(offset, bsize, &block)
  #   Returns a categorical with a block inserted (see
  #   {CArray#insert_block}). The inserted cells are excluded (UNDEF)
  #   unless the block returns one of the labels.
  #   @raise [ArgumentError] when the block returns something that is not
  #     a label.
  def insert_block (offset, bsize, &block)
    fill = block ? code_for_fill(block.call) : UNDEF
    CACategorical.from_codes(codes.insert_block(offset, bsize) { fill }, labels)
  end

  # Boolean mask of cells whose category == label. Excluded cells stay UNDEF
  # (their category is unknown); an unknown label yields an all-false mask.
  # @overload eq(label)
  #   Returns a boolean CArray marking cells whose category equals
  #   `label`. A CArray is compared cell by cell, by label: another
  #   categorical is matched whatever order its labels are in, and a
  #   masked cell on either side gives UNDEF. Anything else, a Ruby Array
  #   included, is one label, as for {CArray#eq}. An unknown label matches
  #   nothing.
  #   @param label [Object, CArray] category to match, or one per cell.
  #   @return [CArray]
  def eq(label)
    codes.eq(codes_of(label))
  end

  # @overload ne(label)
  #   Returns the complement of {#eq}.
  #   @param label [Object, CArray] category to compare against, or one per
  #     cell.
  #   @return [CArray]
  def ne(label)
    codes.ne(codes_of(label))
  end

  # @overload count(label)
  #   Returns the number of cells whose category equals `label`
  #   (0 for an unknown label).
  #   @param label [Object] category to count.
  #   @return [Integer]
  def count(label)
    code = @labels.index(label)
    code ? codes.count(code) : 0
  end

  # Per-category counts as a length-k array aligned to #labels. Trailing empty
  # categories are kept as 0 (unlike codes.bincount, which truncates them), so
  # `labels.zip(category_sizes.to_a)` always pairs up.
  #
  # Memoised: the codes are read-only (immutable storage), so the counts are a
  # pure function of the categorical and stay valid for its lifetime. The same
  # cached array backs {#reduceat_index} and {#sort_addr}, so a wide aggregate
  # over the same categorical pays the count once. (Do not mutate the returned
  # array — it is shared; take `.copy` for a scratch buffer.) A derived-view /
  # composite categorical caches too: read-only rides from the codes as a flag,
  # not a Ruby freeze, so the object stays non-frozen and the memo ivar sticks.
  # @overload category_sizes
  #   Returns per-category counts as a CArray with one entry per {#labels}
  #   aligned to {#labels}. Trailing empty categories are kept as 0
  #   so `labels.zip(category_sizes.to_a)` always pairs up.
  #   @return [CArray]
  def category_sizes
    return @category_sizes if @category_sizes
    bc  = codes.bincount
    out = CArray.new(bc.data_type, [@labels.size], bytes: bc.bytes)   # new zero-fills
    out[0...bc.elements] = bc if bc.elements > 0
    @category_sizes = out
    out
  end

  # Back-compatible alias; {#category_sizes} is the canonical name (a histogram
  # `bincount` reading is misleading for per-category cell counts).
  alias bincount category_sizes

  # ---- value-hash discovery family --------------------------------------
  #
  # The codes are storage and the labels are the values, so this family has to
  # answer in label space.  It cannot ride the family's Face gate: a categorical
  # is not ORDERABLE (code order is the vocabulary's order, not the labels'),
  # and lifting a code array back would still be codes.  Without these overrides
  # `unique` handed back the raw code bytes and `is_in` compared labels against
  # codes, so it was false everywhere.
  #
  # Distinctness itself still rides the codes, where it is a uint8 pass; only the
  # values crossing the surface are translated.  {#count} and {#category_sizes}
  # above are the same idea for a single label / the whole vocabulary.

  # @overload unique(sort: false)
  #   Returns the labels that occur, in first-appearance order.  A category
  #   with no cells is not included (use {#labels} for the vocabulary).
  #   @param sort [Boolean] when true, sort the labels ascending.
  #   @return [CArray] object CArray of labels.
  def unique (sort: false)
    u = labels_for(codes.unique)
    sort ? u.sort : u
  end

  # @overload value_counts(sort: false)
  #   Returns `[labels, counts]` for the categories that occur.  {#category_sizes}
  #   is the aligned-to-{#labels} counterpart, which keeps the empty ones.
  #   @param sort [false, :count, :value] pair ordering.
  #   @return [Array(CArray, CArray)]
  def value_counts (sort: false)
    unless [false, :count, :value].include?(sort)
      raise ArgumentError, "value_counts: sort must be false, :count, or :value"
    end
    code_values, counts = codes.value_counts(sort: sort == :count ? :count : false)
    values = labels_for(code_values)
    return [values, counts] unless sort == :value
    # Ascending *label*: code order is the vocabulary's, so reorder here.
    la    = values.to_a
    order = (0...la.size).sort_by { |i| [la[i], i] }
    idx   = CArray.int64(order.size) { |i| order[i] }
    [values[idx], counts[idx]]
  end

  # @overload mode(axis: nil)
  #   Returns the most frequent label(s).  Runs in label space because the
  #   modal values come back sorted ascending, which for labels is not the
  #   code order.
  #   @return [CArray, Array<CArray>]
  def mode (axis: nil)
    label_values.mode(axis: axis)
  end

  # @overload is_in(values)
  #   Returns a boolean CArray, true where the cell's label is in `values`.
  #   An unknown label matches nothing.  Masked cells stay masked.
  #   @param values [Array, CArray, CACategorical] labels to test against.
  #   @return [CArray]
  def is_in (values)
    refuse_range_set(values, "is_in")
    wanted = label_list(values).filter_map { |l| @labels.index(l) }
    codes.is_in(CArray.int64(wanted.size) { |i| wanted[i] })
  end

  # @overload intersection(other, sort: false)
  #   @return [CArray] object CArray of the labels present in both.
  def intersection (other, sort: false)
    refuse_range_set(other, "intersection")
    unique.intersection(label_array(other), sort: sort)
  end

  # @overload difference(other, sort: false)
  #   @return [CArray] object CArray of the labels only `self` has.
  def difference (other, sort: false)
    refuse_range_set(other, "difference")
    unique.difference(label_array(other), sort: sort)
  end

  # @overload union(other, sort: false)
  #   @return [CArray] object CArray of the labels of either side.
  def union (other, sort: false)
    refuse_range_set(other, "union")
    unique.union(label_array(other), sort: sort)
  end

  # @overload locate_addr(ref)
  #   @return [CArray] for each cell, its label's address in `ref` (UNDEF when
  #     the label does not occur there).
  def locate_addr (ref)
    label_values.locate_addr(label_array(ref))
  end

  private

  # The one decode from a code to its label. An out-of-range code — a negative
  # one, or an unmasked sentinel that reached us from outside — has no label,
  # so it decodes to nil. Writing `@labels[code]` instead would read a negative
  # code from the *end* of the vocabulary and hand back a real label for a cell
  # that has none. Every code-to-label path goes through here rather than
  # indexing @labels itself, because two decodes are two chances to disagree,
  # and disagreeing is how #unique came to contradict #to_a on the same cell.
  # An operand of #eq / #ne as codes of this vocabulary. A value that is not
  # one of the labels gets labels.size, which no cell holds. A CArray is read
  # cell by cell, a masked cell staying masked; a categorical goes through its
  # own codes, so the two vocabularies need not agree. Anything else is one
  # label, as CArray#eq takes it.
  def codes_of (other)
    return @labels.index(other) || @labels.size unless other.is_a?(CArray)
    if other.is_a?(CACategorical)
      table = other.labels.map { |l| @labels.index(l) || @labels.size }
      return CA_INT64(table)[other.codes] unless table.empty?
    end
    memo = {}
    list = other.flatten.to_a.map { |v|
      UNDEF.equal?(v) ? v : memo.fetch(v) { memo[v] = @labels.index(v) || @labels.size }
    }
    CA_INT64(list).reshape(*other.shape)
  end

  # The code a fill value stands for: UNDEF stays UNDEF, a label is its code.
  def code_for_fill (value)
    return UNDEF if UNDEF.equal?(value)
    code = label_position(value)
    raise ArgumentError, "#{value.inspect} is not one of the labels #{labels.inspect}" unless code
    code
  end

  def label_at (code)
    (code < 0 || code >= @labels.size) ? nil : @labels[code]
  end

  # Labels for a code array. The discovery kernels skip masked cells, so what
  # reaches here is real codes — but it is decoded like any other code.
  def labels_for (code_array)
    CA_OBJECT(code_array.to_a.map { |c| label_at(c) })
  end

  # This categorical's cells as their labels; a masked cell stays masked.
  def label_values
    CA_OBJECT(to_a)
  end

  # An operand's labels as a plain Array (a masked cell comes through as UNDEF,
  # which matches no label and so drops out of the set).
  def label_list (other)
    other.respond_to?(:to_a) ? other.to_a : Array(other)
  end

  def label_array (other)
    CA_OBJECT(label_list(other))
  end

  public

  # ---- reduceat / sort-based grouping foundation ------------------------
  #
  # The scatter path (axis_group) handles the monoid reductions (sum / mean /
  # min / max / variance) in one pass. Order statistics (median / percentile)
  # cannot be scattered: they need every value of a group held together. These
  # two accessors are the building blocks for that other engine — lay the data
  # out as category-contiguous blocks, then select per block.
  #
  # The grouping plan — sort_addr (the counting sort, the dominant cost) plus
  # reduceat_index and category_sizes — depends only on the codes, which are
  # read-only. It is therefore memoised (a pure function of the categorical): the
  # first grouping access builds it and every later one reuses it. This is what
  # lets a wide aggregate (many payload columns over one classifier) or a
  # CACategoricalIterator run the counting sort once, not once per column /
  # iterator. Only the plan is cached; the payload-dependent grouped copy
  # (value.reshape(n)[sort_addr]) is rebuilt per column (it varies with value).

  # Force-build (and cache) the whole grouping plan up front — sort_addr,
  # reduceat_index, category_sizes — for prepare-ahead use before a batch of
  # groupings. Lazy building already covers correctness; this is the explicit
  # "pay the counting sort now" handle (e.g. right after `df.group_by(col)`).
  # Returns self so it chains.
  # @overload build_grouping
  #   Eagerly builds and caches the grouping plan (sort_addr / reduceat_index
  #   / category_sizes). Optional — the plan is built lazily on first grouping
  #   access — but useful to pay the counting sort once ahead of a batch.
  #   @return [self]
  def build_grouping
    sort_addr        # pulls category_sizes; reduceat_index shares category_sizes
    reduceat_index
    self
  end

  # Flat addresses that gather self into category-contiguous order: every cell
  # of category 0 first, then 1, ..., then k-1, with excluded cells last. Built
  # by a counting sort over the codes (O(n + k), stable): the segment starts
  # (an exclusive prefix scan of {#category_sizes}) drive a scatter that places
  # each source index into its category's block in source order; excluded cells
  # (masked, or code out of range 0...k) are appended at the tail in source
  # order. The first {#category_sizes}.sum addresses are exactly the classified
  # cells in category order — CACategoricalIterator's permutation. For an N-D
  # categorical the addresses are into the raveled storage, so
  # `value.reshape(elements)[cat.sort_addr]` produces the contiguous blocks.
  # Memoised (see the grouping-plan note above): the counting sort is the
  # dominant grouping cost, so it is computed once and shared by every payload
  # column and by CACategoricalIterator, and kept for the categorical's
  # lifetime (an int64 per cell). Do not mutate the returned array.
  # @overload sort_addr
  #   Returns a length-{#elements} integer CArray of flat storage
  #   addresses that order the cells by category (excluded cells last).
  #   @return [CArray]
  def sort_addr
    return @sort_addr if @sort_addr
    out = codes.reshape(elements).__send__(:addresses_by_category,
                                           reduceat_index.copy, @labels.size,
                                           category_sizes.sum)
    @sort_addr = out
    out
  end

  # Segment start offsets into the category-contiguous layout produced by
  # {#sort_addr}: reduceat_index[c] is where category c's block begins, so
  # block c spans `reduceat_index[c] ... reduceat_index[c] + category_sizes[c]`.
  # Empty categories repeat the following start (a zero-width block). Length k,
  # aligned to #labels; pair with {#category_sizes} for the block lengths. On
  # data already laid out in category order the offsets index it directly.
  # @overload reduceat_index
  #   Returns an int64 CArray, one entry per {#labels}, of segment start
  #   offsets aligned to {#labels}. Pair with {#category_sizes} for lengths.
  #   @return [CArray]
  def reduceat_index
    return @reduceat_index if @reduceat_index
    # Every boundary but the last; the copy makes it an entity the
    # reduceat kernels can read directly.
    @reduceat_index = CArray.segment_offsets(lengths: category_sizes)[0...-1].copy
  end

  # @overload categorize(labels: nil, sort_labels: false)
  #   Returns a {CACategorical} keyed on the labels, as categorizing any
  #   key array does: the labels that occur, in first-appearance order (or
  #   sorted with `sort_labels:`), or the fixed `labels:` vocabulary.  A
  #   category of `self` with no cells does not carry over; a masked cell
  #   is excluded.
  #   @return [CACategorical]
  def categorize (labels: nil, sort_labels: false)
    if labels || sort_labels
      return label_values.categorize(labels: labels, sort_labels: sort_labels)
    end
    # Distinctness rides the codes; only the k labels cross the surface.
    recoded = codes.categorize
    CACategorical.from_codes(recoded.codes, recoded.labels.map { |c| label_at(c) })
  end

  # The position of +label+ among the labels, found by ==, a NaN label by a
  # NaN, as join and at match NaN keys; nil when it is not one of them.
  private def label_position (label)
    return @labels.index(label) unless label.is_a?(Float) && label.nan?
    @labels.index { |l| l.is_a?(Float) && l.nan? }
  end

  # The categorical as numeric columns, one per category, for a model that
  # takes numbers: row i holds 1 in the column of its category and 0
  # elsewhere.  With an intercept in the model the k columns would sum to the
  # intercept's column, so by default the column of the base category is
  # left out and k - 1 remain; each coefficient then reads as that category
  # minus the base.  +full: true+ keeps all k (a model without an intercept,
  # or an input to a learner).
  #
  # The columns follow the labels, not the data: a category with no cells
  # gives a column of zeros, so two categoricals with the same labels give
  # the same columns.  A masked cell gives a masked row.
  #
  # @overload contrast(scheme = :dummy, base: nil, full: false)
  #   Returns an int8 CArray of shape (n, k - 1), or (n, k) with
  #   `full: true`, whose columns are the labels in order with the base
  #   left out.
  #   @param scheme [Symbol] the coding; only `:dummy` is defined.
  #   @param base [Object] the label whose column is left out; the first
  #     label when omitted.
  #   @param full [Boolean] keep every column.
  #   @return [CArray]
  #   @raise [ArgumentError] when `scheme` is not `:dummy`, when `base` is
  #     not a label, when `base:` and `full: true` are both given, when
  #     there are no labels to leave one out of, or when the categorical is
  #     not one-dimensional.
  def contrast (scheme = :dummy, base: nil, full: false)
    unless scheme == :dummy
      raise ArgumentError, "contrast: unknown scheme #{scheme.inspect} (only :dummy is defined)"
    end
    unless ndim == 1
      raise ArgumentError, "contrast: the categorical is #{ndim}-dimensional, not one-dimensional"
    end
    k = @labels.size
    if full
      raise ArgumentError, "contrast: base: and full: true contradict (full keeps every column)" unless base.nil?
      kept = (0...k).to_a
    else
      raise ArgumentError, "contrast: there are no labels, so no base column to leave out" if k == 0
      dropped = base.nil? ? 0 : label_position(base)
      raise ArgumentError, "contrast: #{base.inspect} is not one of the labels #{@labels.inspect}" unless dropped
      kept = (0...k).to_a - [dropped]
    end
    n   = elements
    m   = kept.size
    out = CArray.int8(n, m).zero
    return out if n == 0 || m == 0

    # One pass: each cell's code picks its column through colmap (-1 for the
    # base), and a 1 is written at row * m + column.
    colmap = CArray.int64(k) { -1 }
    kept.each_with_index { |code, j| colmap[code] = j }
    excluded = codes.has_mask? ? codes.is_masked : CArray.boolean(n) { false }
    code = codes.value.to_type(CA_INT64)
    code[excluded] = 0 if excluded.any
    col  = colmap[code]
    hit  = col.ge(0) & excluded.not
    addr = CArray.int64(n).seq! * m + col
    out.reshape(n * m)[addr[hit]] = 1 if hit.any
    out[excluded, nil] = UNDEF if excluded.any
    out
  end

  # @overload inspect
  #   Returns a short summary showing element count, category count,
  #   and vocabulary.
  #   @return [String]
  def inspect
    "#<CACategorical n=#{elements} categories=#{@labels.size} labels=#{@labels.inspect}>"
  end
end


class CArray
  # Build a CACategorical from self read as category keys (= the values whose
  # distinct levels become the categories). Codes are dense 0-based in the
  # order labels appear (first-appearance by default, or ascending sorted
  # when `sort_labels: true`); masked keys become masked (excluded) codes.
  #
  #   labels: nil                        -> discover, first-appearance order
  #   labels: nil, sort_labels: true     -> discover, then sort ascending
  #   labels: set                        -> fixed vocabulary (must be unique);
  #                                         keys outside it are excluded (masked)
  # @overload categorize(labels: nil, sort_labels: false)
  #   Returns a {CACategorical} built from `self` read as category
  #   keys. With `labels: nil` distinct levels are discovered in
  #   first-appearance order (or ascending sorted when
  #   `sort_labels: true`); with an explicit `labels` list the
  #   vocabulary is fixed and keys outside it become masked
  #   (excluded). `sort_labels:` is ignored when an explicit `labels`
  #   is given (the caller has already chosen the order).
  #   @param labels [Array, CArray, nil] fixed vocabulary; `nil`
  #     enables discovery.
  #   @param sort_labels [Boolean] when discovering (labels: nil), sort
  #     the discovered vocabulary ascending after collecting it.
  #   @return [CACategorical]
  #   @raise [ArgumentError] when explicit `labels` contain
  #     duplicates.
  #   @raise [CArray::DataTypeError] when `sort_labels: true` discovers
  #     the labels of a complex array, which have no order.
  # The order sort_labels: puts two labels in: the order sort puts the cells
  # of an array in (object_order_cmp); two labels <=> cannot order are
  # refused, by name.
  private def label_order(a, b)
    c = CArray.send(:object_order_cmp, a, b)
    if c.nil?
      raise ArgumentError,
            "categorize(sort_labels: true): cannot order the labels " \
            "#{a.inspect} and #{b.inspect}"
    end
    c
  end

  def categorize(labels: nil, sort_labels: false)
    # Automatic appearance-order vocabulary: one linear pass (C
    # __factorize_appearance__) returns both codes and levels directly, over the
    # integer / float / object / fixlen / boolean lanes (boolean rides the uint8
    # lane). Distinctness is the hash-key judgement shared with the discovery
    # family: Float NaN collapses to one category and -0.0 == +0.0, while mixed
    # Integer / Float keys stay distinct (eql?, so 1 and 1.0 are separate
    # categories). Complex values are distinct by value with the same NaN and
    # -0.0 rules, and have no order, so sort_labels refuses them. The discovery
    # path below is reserved for an explicit labels list.
    if labels.nil? && sort_labels && complex?
      raise CArray::DataTypeError,
            "categorize(sort_labels: true): a #{data_type_name} value has no " \
            "order (complex numbers are not ordered); without sort_labels: the " \
            "labels are in first-appearance order"
    end
    if labels.nil? && (integer? || float? || complex? || object? || fixlen? || boolean?)
      codes, levels = __factorize_appearance__
      levels = levels.to_a
      return CACategorical.from_codes(codes, levels) unless sort_labels
      # Sort the k levels as Ruby sorts them, then renumber every code through
      # the rank in one gather. The sentinel of an excluded cell is out of the
      # rank's range, so project makes it UNDEF and from_codes writes it back.
      # A boolean label reads as true or false, and sorts as its storage,
      # false before true, as sort and unique(sort: true) put the cells.
      order = if boolean?
                (0...levels.size).sort_by { |i| levels[i] ? 1 : 0 }
              else
                (0...levels.size).sort { |i, j| label_order(levels[i], levels[j]) }
              end
      rank = CArray.new(codes.data_type, [levels.size])
      order.each_with_index { |old, new_code| rank[old] = new_code }
      return CACategorical.from_codes(rank.project(codes), order.map { |i| levels[i] })
    end

    if labels.nil?
      # Discover the levels in first-appearance order: mask_duplicates keeps the
      # first occurrence of each distinct value and masks the rest (already-
      # masked keys stay excluded), so the non-masked cells are the levels.
      # Only the final list is Ruby, since labels are Ruby objects.
      labels_arr = mask_duplicates[:is_not_masked].to_a
      labels_arr.sort! { |a, b| label_order(a, b) } if sort_labels
    else
      labels_arr = labels.respond_to?(:to_a) ? labels.to_a : Array(labels)
      if labels_arr.uniq.size != labels_arr.size
        raise ArgumentError, "categorize: labels: must be unique (got duplicates)"
      end
    end

    # Choose a narrow unsigned code type, reserving its top value as the
    # exclusion sentinel so it never collides with a real code 0..k-1.
    k = labels_arr.size
    code_type, sentinel =
      if    k <= 0xFF   then [CA_UINT8,  0xFF]
      elsif k <= 0xFFFF then [CA_UINT16, 0xFFFF]
      else                   [CA_UINT32, 0xFFFFFFFF]
      end

    # One vectorized masked write per category. Cells matching no category
    # (out-of-vocabulary) and masked cells (eq yields UNDEF, skipped) keep the
    # sentinel; from_codes then derives the mask from it.
    codes = CArray.new(code_type, shape).fill(sentinel)
    labels_arr.each_with_index { |label, c| codes[eq(label)] = c }

    CACategorical.from_codes(codes, labels_arr)
  end
end

# categorize is a conversion: the categories are the values in another
# representation, so they show the attributes the values show.  Each of the
# three implementations returns from several places, so the attributes are
# carried here, around all of them.
[CArray, CACategorical, CAConstString].each do |klass|
  klass.prepend(Module.new do
    def categorize (labels: nil, sort_labels: false)
      carry_attrs(super)
    end
  end)
end

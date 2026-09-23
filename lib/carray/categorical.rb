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
    super(CA_FIXLEN, codes.dim,
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
  def storage_to_scalar(raw)
    code = raw.is_a?(String) ? raw.unpack1(UNPACK_FORMAT.fetch(parent.data_type)) : raw
    label_at(code)
  end

  # ---- category-space operations (by label, not code) -------------------
  #
  # The element value of a categorical IS its category, so these specialise
  # CArray's value operations into label space — the user never has to know
  # the integer code. The raw codes stay reachable via #codes for code-space
  # work (interop, ML features), but they are not the everyday surface.

  # Boolean mask of cells whose category == label. Excluded cells stay UNDEF
  # (their category is unknown); an unknown label yields an all-false mask.
  # @overload eq(label)
  #   Returns a boolean CArray marking cells whose category equals
  #   `label`. Excluded cells stay masked; an unknown label yields
  #   an all-false result.
  #   @param label [Object] category to match.
  #   @return [CArray]
  def eq(label)
    codes.eq(@labels.index(label) || @labels.size)
  end

  # @overload ne(label)
  #   Returns the complement of {#eq}.
  #   @param label [Object] category to compare against.
  #   @return [CArray]
  def ne(label)
    codes.ne(@labels.index(label) || @labels.size)
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
    return @_category_sizes if @_category_sizes
    bc  = codes.bincount
    out = CArray.new(bc.data_type, [@labels.size])   # new zero-fills
    out[0...bc.elements] = bc if bc.elements > 0
    @_category_sizes = out
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
    wanted = label_list(values).filter_map { |l| @labels.index(l) }
    codes.is_in(CArray.int64(wanted.size) { |i| wanted[i] })
  end

  # @overload intersection(other, sort: false)
  #   @return [CArray] object CArray of the labels present in both.
  def intersection (other, sort: false)
    unique.intersection(label_array(other), sort: sort)
  end

  # @overload difference(other, sort: false)
  #   @return [CArray] object CArray of the labels only `self` has.
  def difference (other, sort: false)
    unique.difference(label_array(other), sort: sort)
  end

  # @overload union(other, sort: false)
  #   @return [CArray] object CArray of the labels of either side.
  def union (other, sort: false)
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
  # column and by CACategoricalIterator. Do not mutate the returned array.
  # @overload sort_addr
  #   Returns a length-{#elements} integer CArray of flat storage
  #   addresses that order the cells by category (excluded cells last).
  #   @return [CArray]
  def sort_addr
    return @_sort_addr if @_sort_addr
    n      = elements
    k      = @labels.size
    cs     = category_sizes                       # per-category counts
    nvalid = cs.sum
    cur    = CArray.int64(k > 0 ? k : 0)          # segment starts, consumed as cursor
    cur[1..-1] = cs.cumsum.int64[0..-2] if k > 1
    flat   = codes.reshape(n)
    seq    = CArray.int64(n).seq!                 # source indices, scattered as payload
    out    = CArray.int64(n)
    if nvalid == n
      flat.send(:__categorical_scatter__, seq, cur, out, k) # all valid: scatter straight in
    else
      if nvalid > 0
        valid = CArray.int64(nvalid)              # scatter target must be an entity, not a view
        flat.send(:__categorical_scatter__, seq, cur, valid, k)
        out[0...nvalid] = valid
      end
      # Excluded = every cell the scatter skips: code out of [0, k), OR masked
      # (a from_codes pre-masked cell keeps a valid code but is excluded). Both
      # must be caught or the tail slot count would not add up to n - nvalid.
      excluded = flat.value.ge(k).or(flat.value.lt(0))
      excluded = excluded.or(flat.is_masked) if flat.has_mask?
      out[nvalid..-1] = seq[excluded]             # excluded cells, source order
    end
    @_sort_addr = out
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
    return @_reduceat_index if @_reduceat_index
    k = @labels.size
    out = CArray.int64(k > 0 ? k : 0)
    if k > 1
      out[0] = 0
      out[1..-1] = category_sizes.cumsum.int64[0..-2]
    elsif k == 1
      out[0] = 0
    end
    @_reduceat_index = out
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
  def categorize(labels: nil, sort_labels: false)
    # Automatic appearance-order vocabulary: one linear pass (C
    # __factorize_appearance__) returns both codes and levels directly, over the
    # integer / float / object / fixlen / boolean lanes (boolean rides the uint8
    # lane). Distinctness is the hash-key judgement shared with the discovery
    # family: Float NaN collapses to one category and -0.0 == +0.0, while mixed
    # Integer / Float keys stay distinct (eql?, so 1 and 1.0 are separate
    # categories). The discovery path below is reserved for sort_labels (which
    # reorders the vocabulary, desyncing the appearance-order codes), an explicit
    # labels list, and the data types the factorize kernel does not take (complex).
    if labels.nil? && !sort_labels && (integer? || float? || object? || fixlen? || boolean?)
      codes, levels = __factorize_appearance__
      return CACategorical.from_codes(codes, levels.to_a)
    end

    if labels.nil?
      # Discover the levels in first-appearance order: mask_duplicates keeps the
      # first occurrence of each distinct value and masks the rest (already-
      # masked keys stay excluded), so the non-masked cells are the levels.
      # Only the final list is Ruby, since labels are Ruby objects.
      labels_arr = mask_duplicates[:is_not_masked].to_a
      labels_arr.sort! if sort_labels
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

#  CAStruct::Builder -- the DSL backend behind CArray.struct { ... } and
#  CArray.union { ... }.  Autoloaded from lib/carray/struct.rb on first
#  reference to CAStruct::Builder, so applications that only consume
#  pre-defined struct classes never pay for loading the Builder.

# ---------------------------------------------------------------------
#
# Struct Builder Class
#
# ---------------------------------------------------------------------

class CAStruct::Builder  # :nodoc:

  class Member # :nodoc:

    def initialize (name, type, opt={})
      @name, @type, @opt = name, type, opt
      if @type == :bitfield
        # Bit members carry their own offset/length math via the
        # Builder's bit() method; the standard byte cursor in
        # member() does not advance for them.  Setting byte_length=0
        # keeps any defensive byte-loop arithmetic harmless.
        @bytes       = 0
        @byte_length = 0
      elsif @type.kind_of?(CArray)
        @type = @type.copy
        @byte_length = @type.bytes * @type.elements
        @bytes  = 0
      else
        data_type, @bytes = CArray.guess_type_and_bytes(@type, @opt[:bytes])
        if data_type == CA_OBJECT
          raise CAStruct::DefinitionError,
                "CA_OBJECT cannot be a member of struct or union"
        end
        @byte_length = @bytes
      end
      @offset = @opt[:offset]
    end

    attr_reader :name, :type, :offset, :bytes, :byte_length, :opt

  end

  # Build the DISPATCH_TABLE for a finalized MEMBER_TABLE.
  # Returns `{ name => [reader_proc, writer_proc] }` where each Proc
  # closes over the per-member offset / opts.  Called once, at the
  # bottom of `define`.  Public so it can be tested in isolation.
  #
  # `data_size` is the struct's DATA_SIZE; needed up front so we can
  # bounds-check bit-field projections at definition time rather than
  # at first access.
  def self.build_dispatch_table (member_table, data_size)
    dispatch = {}
    member_table.each do |name, entry|
      offset, type, opts = *entry
      case
      when type == :bitfield
        dispatch[name] = build_bitfield_dispatcher(name, opts, data_size)
      when type.is_a?(Class)
        dispatch[name] = build_nested_struct_dispatcher(offset, type)
      when type.is_a?(CArray)
        dispatch[name] = build_carray_template_dispatcher(offset, type)
      else
        dispatch[name] = build_primitive_dispatcher(offset, type, opts)
      end
    end
    dispatch
  end

  # CIFY: build the FAST_PRIMITIVES table consumed by the C-native
  # CAStruct#[] / #[]=.  Includes the members the C path can handle
  # without allocating any CAField / CABitfield / CAByteSwap view:
  #
  #   - Plain primitives (int8..uint64, float32/64) without `endian:`
  #   - Bit-fields: word load + shift + mask in C
  #   - Endian-tagged primitives: __builtin_bswap in C, but
  #     only when the requested endian differs from the host -- when
  #     they match, the member is folded into the primitive path with
  #     no swap at all.
  #
  # Bit-fields whose spanning power-of-2 word reaches past
  # `data_size` cannot be fast-pathed (CABitfield's existing guard
  # also rejects them); they fall through to DISPATCH_TABLE so the
  # Ruby Proc can produce a clear DefinitionError-style failure.
  #
  # Nested-struct / CArray-template / fixlen / cmplx / object stay
  # absent; for them the C path falls back to DISPATCH_TABLE's Proc.
  #
  # Entry shape: `name => [kind, ...args]` (frozen Array).
  #
  #   FAST_KIND_PRIMITIVE = 0
  #     [0, offset, ca_type_code]
  #   FAST_KIND_BITFIELD = 1
  #     [1, start_byte, view_bytes, bit_in_word, bits]
  #   FAST_KIND_ENDIAN = 2
  #     [2, offset, ca_type_code]
  #
  # Kind tags are kept in sync with FAST_KIND_* in
  # ext/carray_struct.c.
  FAST_KIND_PRIMITIVE = 0
  # @!visibility private
  FAST_KIND_BITFIELD  = 1
  # @!visibility private
  FAST_KIND_ENDIAN    = 2

  # @!visibility private
  def self.build_fast_primitives (member_table, data_size = nil)
    fast = {}
    host_endian = CArray.endian
    member_table.each do |name, entry|
      offset, type, opts = *entry
      case
      when type == :bitfield
        fast_entry = build_fast_bitfield_entry(opts, data_size)
        fast[name] = fast_entry if fast_entry
      when type.is_a?(Class)
        # nested struct — DISPATCH_TABLE
      when type.is_a?(CArray)
        # CArray template — DISPATCH_TABLE
      else
        type_code = FAST_PRIMITIVE_TYPE_CODES[type]
        next unless type_code
        endian = opts && opts[:endian]
        if endian && endian_needs_swap?(endian, host_endian) &&
           ENDIAN_FAST_TYPE_CODES.include?(type_code)
          fast[name] = [FAST_KIND_ENDIAN, offset, type_code].freeze
        else
          fast[name] = [FAST_KIND_PRIMITIVE, offset, type_code].freeze
        end
      end
    end
    fast
  end

  # Bit-field FAST entry, mirroring build_bitfield_dispatcher's
  # geometry calculation but emitting the C-friendly tuple
  # [FAST_KIND_BITFIELD, start_byte, view_bytes, bit_in_word, bits].
  # Returns nil if the field can't be fast-pathed (e.g. its spanning
  # word reaches past DATA_SIZE -- the existing build_bitfield_dispatcher
  # raises in that case at definition time; here we just bow out and
  # let DISPATCH_TABLE raise).
  def self.build_fast_bitfield_entry (opts, data_size)
    bits       = opts[:bits]
    bit_offset = opts[:bit_offset]
    start_byte = bit_offset / 8
    bit_in_word = bit_offset % 8
    span       = (bit_offset + bits + 7) / 8 - start_byte
    view_bytes = case
                 when span <= 1 then 1
                 when span <= 2 then 2
                 when span <= 4 then 4
                 else                8
                 end
    return nil if data_size && start_byte + view_bytes > data_size
    [FAST_KIND_BITFIELD, start_byte, view_bytes, bit_in_word, bits].freeze
  end

  # True iff a member tagged with the given `endian:` keyword needs
  # an actual byte swap on the current host.  Matches CArray#endian's
  # short-circuit logic: :preserve and :native are always identity;
  # :big / :little are identity when the host already matches.
  def self.endian_needs_swap? (endian_sym, host_endian)
    case endian_sym
    when :preserve, :native then false
    when :big    then host_endian != CA_BIG_ENDIAN
    when :little then host_endian != CA_LITTLE_ENDIAN
    else false   # unknown sym — be conservative, defer to DISPATCH_TABLE
    end
  end

  # Symbol → CA_* integer constant for the primitive numeric types
  # the C fast path handles directly.  Anything missing here routes
  # through DISPATCH_TABLE (slower but correct).
  # These values are consumed by the C-side FAST_PRIMITIVES dispatcher
  # (ext/carray_struct.c) which expects raw int8_t data_type codes via
  # NUM2INT.  CA_* are Symbols, so we eagerly convert to Integer codes
  # here at definition time.
  FAST_PRIMITIVE_TYPE_CODES = {
    :boolean => CArray.data_type_code(CA_BOOLEAN),
    :int8    => CArray.data_type_code(CA_INT8),
    :uint8   => CArray.data_type_code(CA_UINT8),
    :int16   => CArray.data_type_code(CA_INT16),
    :uint16  => CArray.data_type_code(CA_UINT16),
    :int32   => CArray.data_type_code(CA_INT32),
    :uint32  => CArray.data_type_code(CA_UINT32),
    :int64   => CArray.data_type_code(CA_INT64),
    :uint64  => CArray.data_type_code(CA_UINT64),
    :float32 => CArray.data_type_code(CA_FLOAT32),
    :float64 => CArray.data_type_code(CA_FLOAT64),
  }.freeze

  # ca_type_code → eligible for the endian-swapped fast path.  1-byte
  # types are excluded because byte-swap is a no-op (they go through
  # the plain primitive path).  Complex types are excluded too;
  # their per-component swap matches CAByteSwap behaviour and stays
  # on the DISPATCH_TABLE Proc.  Values are Integer codes (same
  # rationale as FAST_PRIMITIVE_TYPE_CODES above).
  ENDIAN_FAST_TYPE_CODES = FAST_PRIMITIVE_TYPE_CODES.values_at(
    :int16, :uint16, :int32, :uint32, :int64, :uint64,
    :float32, :float64,
  ).freeze

  # -- per-kind dispatcher builders -------------------------------------

  def self.build_bitfield_dispatcher (name, opts, data_size)
    bits       = opts[:bits]
    bit_offset = opts[:bit_offset]
    start_byte = bit_offset / 8
    bit_in_byte = bit_offset % 8
    span       = (bit_offset + bits + 7) / 8 - start_byte
    view_bytes = case
                 when span <= 1 then 1
                 when span <= 2 then 2
                 when span <= 4 then 4
                 else                8
                 end
    if start_byte + view_bytes > data_size
      raise CAStruct::DefinitionError,
            "bit member #{name.inspect} (bit_offset=#{bit_offset}, " \
            "bits=#{bits}) needs a #{view_bytes}-byte view starting " \
            "at byte #{start_byte}, but the record is only " \
            "#{data_size} bytes — deferred to A.3+ (multi-byte bit " \
            "members spanning unaligned record tails)"
    end
    vtype = {1 => :uint8, 2 => :uint16, 4 => :uint32, 8 => :uint64}[view_bytes]
    range = bit_in_byte..(bit_in_byte + bits - 1)
    reader = ->(data) {
      data.field(start_byte, vtype).bitfield(range)[0]
    }
    writer = ->(data, val) {
      data.field(start_byte, vtype).bitfield(range)[0] = val
    }
    [reader, writer].freeze
  end

  # @!visibility private
  def self.build_nested_struct_dispatcher (offset, nested_class)
    reader = ->(data) { nested_class.decode(data.field(offset, nested_class)) }
    writer = ->(data, val) { data.field(offset, nested_class)[0] = val }
    [reader, writer].freeze
  end

  # @!visibility private
  def self.build_carray_template_dispatcher (offset, template)
    reader = ->(data) { data.field(offset, template)[0, false] }
    writer = ->(data, val) { data.field(offset, template)[0, false] = val }
    [reader, writer].freeze
  end

  # @!visibility private
  def self.build_primitive_dispatcher (offset, type, opts)
    # Specialise the reader/writer to the smallest amount of work
    # this particular member needs: no opts → 2-arg field; opts with
    # only :bytes → 3-arg field; opts with :endian → 3-arg field +
    # endian view chain.
    endian = opts && opts[:endian]
    if opts.nil?
      reader = ->(data) { data.field(offset, type)[0] }
      writer = ->(data, val) { data.field(offset, type)[0] = val }
    elsif endian.nil?
      reader = ->(data) { data.field(offset, type, opts)[0] }
      writer = ->(data, val) { data.field(offset, type, opts)[0] = val }
    else
      # CArray#field only accepts `bytes:`; the endian swap is applied by
      # the chained #endian view, not by field.  Strip :endian from the
      # hash handed to field so it is not rejected.
      field_opts = opts.reject { |k, _| k == :endian }
      if field_opts.empty?
        reader = ->(data) { data.field(offset, type).endian(endian)[0] }
        writer = ->(data, val) { data.field(offset, type).endian(endian)[0] = val }
      else
        reader = ->(data) { data.field(offset, type, field_opts).endian(endian)[0] }
        writer = ->(data, val) {
          data.field(offset, type, field_opts).endian(endian)[0] = val
        }
      end
    end
    [reader, writer].freeze
  end

  # @!visibility private
  ALIGN_TABLE = {
    CA_FIXLEN   => CA_ALIGN_FIXLEN,
    CA_BOOLEAN  => CA_ALIGN_INT8,
    CA_INT8     => CA_ALIGN_INT8,
    CA_UINT8    => CA_ALIGN_INT8,
    CA_INT16    => CA_ALIGN_INT16,
    CA_UINT16   => CA_ALIGN_INT16,
    CA_INT32    => CA_ALIGN_INT32,
    CA_UINT32   => CA_ALIGN_INT32,
    CA_INT64    => CA_ALIGN_INT64,
    CA_UINT64   => CA_ALIGN_INT64,
    CA_FLOAT32  => CA_ALIGN_FLOAT32,
    CA_FLOAT64  => CA_ALIGN_FLOAT64,
    CA_CMPLX64  => CA_ALIGN_FLOAT32,
    CA_CMPLX128 => CA_ALIGN_FLOAT64,
  }

  def initialize (type, opt = {})
    if not opt[:pack].nil? and not opt[:pack].is_a?(Integer)
      raise CAStruct::DefinitionError,
            "invalid :pack value #{opt[:pack].inspect} (expected nil or Integer)"
    end
    @type       = type       ### :struct or :union
    @align      = opt[:pack] ### nil for alignment, int for pack(n)
    @members    = []         ### array of CArray::Struct::Builder::Member
    @offset     = 0          ### offset of each member and size of struct
    @align_max  = 1          ### maximum of alignment among members
    @size       = opt[:size] ### user defined struct size
    @bit_offset = 0          ### 0..7, sub-byte position for bitfield accumulator
  end

  # Round up the byte cursor if the bitfield accumulator is mid-byte.
  # Called before placing a non-bit member so the byte member starts
  # on a clean byte boundary (and after the body is fully built so
  # DATA_SIZE includes the trailing bits' byte).
  def flush_bit_offset
    if @bit_offset > 0
      @offset += 1
      @bit_offset = 0
    end
  end

  # @!visibility private
  def define (&block)
    # ---
    case block.arity
    when 1
      block.call(self)      ### struct/union definition block
    when -1, 0
      instance_exec(&block) ### struct/union definition block
    else
      raise CAStruct::DefinitionError,
            "invalid # of block parameters (expected 0 or 1)"
    end
    # Flush any trailing bit accumulator so DATA_SIZE includes the
    # final byte that carries the last bit member's tail.
    flush_bit_offset
    # ---
    # Detect duplicate member names before doing anything else.  A
    # duplicate would silently overwrite MEMBER_TABLE entries and
    # produce a struct whose MEMBERS list contains the same name
    # twice, which downstream code (MEMBERS.map { ... }, define_method
    # loop, .spec) cannot recover from cleanly.
    seen = {}
    dups = []
    @members.each do |mem|
      if seen[mem.name]
        dups << mem.name
      else
        seen[mem.name] = true
      end
    end
    unless dups.empty?
      raise CAStruct::DefinitionError,
            format("duplicate member name(s): %s",
                   dups.uniq.map(&:inspect).join(", "))
    end
    # ---
    case @type
    when :struct
      klass = Class.new(CAStruct)
    when :union
      klass = Class.new(CAUnion)
    end
    # ---
    if @align.nil?
      @offset = alignment(@offset, :align_max)
    end
    if @size
      if @size < @offset
        raise CAStruct::DefinitionError,
              format("declared :size (%d) is smaller than packed body (%d)",
                     @size, @offset)
      end
      @offset = @size
    end
    klass.const_set(:DATA_SIZE, @offset)   ### required element as data class
    # ---
    table = Hash.new
    names = []
    @members.each do |mem|
      name   = mem.name
      type   = mem.type
      offset = mem.offset
      bytes  = mem.bytes
      if type == :bitfield
        # Bit members carry their addressing info (bits + bit_offset)
        # in opts; CAStruct#[] / #[]= dispatches on this type and
        # routes to @data.bitfield(bit_offset, bits).
        table[name] = [offset, :bitfield,
                       { :bits       => mem.opt[:bits],
                         :bit_offset => mem.opt[:bit_offset] }]
      elsif bytes
        ent = {:bytes => bytes}
        ent[:endian] = mem.opt[:endian] if mem.opt[:endian]
        table[name] = [offset, type, ent]
      elsif mem.opt[:endian]
        table[name] = [offset, type, {:endian => mem.opt[:endian]}]
      else
        table[name] = [offset, type]
      end
      names.push(name)
    end
    table.freeze
    names.freeze
    klass.const_set(:MEMBER_TABLE, table)   ### required element as data class
    klass.const_set(:MEMBERS, names)
    # ---
    # Step 3 dispatch table: precompute a per-member [reader, writer]
    # Proc pair so `record[name]` is one Hash lookup + one Proc call,
    # with no `case type` reclassification on each access.  All bounds
    # checks and view-shape decisions happen here, once, at class
    # definition time.
    klass.const_set(:DISPATCH_TABLE,
                    self.class.build_dispatch_table(table, @offset).freeze)
    # Also precompute FAST_PRIMITIVES, the subset of members that the
    # C-side `[]` / `[]=` can handle without
    # allocating a CAField view.  Entries are `[offset, type_code]`;
    # the C reader does a typed memcpy + INT2FIX/DBL2NUM/... directly
    # on @data.ptr + offset.  Bit / endian / nested / template / fixlen
    # members are absent here -- they stay on the DISPATCH_TABLE Proc
    # path.
    klass.const_set(:FAST_PRIMITIVES,
                    self.class.build_fast_primitives(table, @offset).freeze)
    # ---
    klass.module_eval {
      names.each do |name|
        define_method(name) {
          return self[name]
        }
        define_method("#{name}=") { |val|
          return self[name] = val
        }
      end
    }
    # ---
    return klass
  end

  private

  def alignment (addr, data_type, opt={})
    # ALIGN_TABLE keys are CA_* constants, which are Symbols.  Dispatch on
    # Symbol directly; the Integer path (= raw data_type code) maps via the
    # canonical Symbol name.
    case data_type
    when :align_max
      align = @align_max
    when Symbol
      align = ALIGN_TABLE[data_type]
      unless align
        data_type, bytes = CArray.guess_type_and_bytes(data_type, opt[:bytes])
        return alignment(addr, data_type, :bytes=>bytes)
      end
    when Integer
      align = ALIGN_TABLE[CArray.data_type_name(data_type).to_sym]
    when CArray, Class
      align = CA_ALIGN_VOIDP
    else
      data_type, bytes = CArray.guess_type_and_bytes(data_type, opt[:bytes])
      return alignment(addr, data_type, :bytes=>bytes)
    end
    if align > @align_max
      @align_max = align
    end
    if ( d = addr % align ) != 0
      addr += (align - d)
    end
    return addr
  end

  def pack (addr, align, opt={})
    if ( addr % align ) != 0
      raise CAStruct::DefinitionError,
            format("invalid offset for packing: %d not aligned to %d", addr, align)
    end
    return addr
  end

  public

  # @overload member(data_type, id = nil, opt = {})
  #   Declares a member with the given storage `data_type`. Used
  #   internally by the typed DSL methods (`int32`, `float64`, ...);
  #   call directly to place a custom template or nested type.
  #   @param data_type [Object] data type (Symbol, Integer, CArray
  #     template, or nested struct class).
  #   @param id [Symbol, String, nil] member name; auto-generated
  #     when `nil`.
  #   @param opt [Hash] member options (`:offset`, `:bytes`, `:endian`, ...).
  #   @return [Member]
  def member (data_type, id = nil, opt = {})
    opt = opt.clone
    # If a bit member sequence was in flight, round up to a clean byte
    # boundary before placing this byte-typed member.
    flush_bit_offset
    if id
      id = id.to_s
    else
      id = "#{@members.size}"
    end
    case @type
    when :struct                           ### struct
      case @align
      when nil                             ### -- aligned
        @offset = alignment(@offset, data_type, opt)
        opt[:offset] = @offset
      else                                 ### -- packed
        if opt[:offset]                    ### ---- explicit offset
          @offset = pack(opt[:offset], @align, opt)
        else
          opt[:offset] = @offset           ### ---- auto offset
        end
      end
      mem = Member.new(id, data_type, opt)
      @members.push(mem)
      @offset += mem.byte_length
    when :union                            ### union
      alignment(0, data_type, opt)
      opt[:offset] = 0
      mem = Member.new(id, data_type, opt)
      @members.push(mem)
      if mem.byte_length > @offset
        @offset = mem.byte_length
      end
    end
  end

  # @overload struct(*names, &block)
  #   Declares a nested struct member. With a block, defines an
  #   inline nested struct; otherwise requires `type:` naming an
  #   existing {CAStruct} subclass.
  #   @param names [Array<Symbol>] member names.
  #   @return [Class] the nested struct class.
  #   @raise [CAStruct::DefinitionError] when neither a block nor
  #     `type:` is provided.
  def struct (*args, &block)
    opt = args.last.is_a?(Hash) ? args.pop : {}
    if block
      opt = {:pack => @align}.update(opt)
      st = self.class.new(:struct, opt).define(&block)
    elsif opt[:type] and opt[:type] <= CAStruct
      st = opt[:type]
    else
      raise CAStruct::DefinitionError,
            "no type given for nested struct member (pass a block or :type)"
    end
    args.each do |arg|
      member(st, arg)
    end
    return st
  end

  # @overload union(*names, &block)
  #   Declares a nested union member. With a block, defines an
  #   inline nested union; otherwise requires `type:` naming an
  #   existing {CAUnion} subclass.
  #   @param names [Array<Symbol>] member names.
  #   @return [Class] the nested union class.
  #   @raise [CAStruct::DefinitionError] when neither a block nor
  #     `type:` is provided.
  def union (*args, &block)
    opt = args.last.is_a?(Hash) ? args.pop : {}
    if block
      opt = {:pack => @align}.update(opt)
      st = self.class.new(:union, opt).define(&block)
    elsif opt[:type] and opt[:type] <= CAStruct
      st = opt[:type]
    else
      raise CAStruct::DefinitionError,
            "no type given for nested union member (pass a block or :type)"
    end
    args.each do |arg|
      member(st, arg)
    end
    return st
  end

  # @overload array(*names, type:)
  #   Declares one or more members holding a CArray template.
  #   @param names [Array<Symbol>] member names.
  #   @return [void]
  #   @raise [CAStruct::DefinitionError] when `type:` is not a
  #     CArray template.
  def array (*args)
    opt = args.last.is_a?(Hash) ? args.pop : {}
    if not opt[:type] or not opt[:type].kind_of?(CArray)
      raise CAStruct::DefinitionError,
            "no :type given for array member (expected a CArray template)"
    end
    args.each do |arg|
      member(opt[:type], arg)
    end
  end

  # @overload bit(name, bits:)
  #   Declares a bitfield member. Bits accumulate within the
  #   current byte; when a byte member follows, the cursor rounds
  #   up to the next byte boundary. Only supported in `:struct`
  #   (not `:union`) and always requires a name.
  #   @param name [Symbol, String] member name.
  #   @param bits [Integer] bit width in `1..64`.
  #   @return [void]
  #   @raise [CAStruct::DefinitionError] on `:union` context, a
  #     missing name, or an invalid `bits` value.
  def bit (name, bits:)
    if @type == :union
      raise CAStruct::DefinitionError,
            "bit members in :union are not supported"
    end
    if name.nil?
      raise CAStruct::DefinitionError,
            "bit member must have a name (no anonymous bit padding)"
    end
    unless bits.is_a?(Integer) && bits >= 1 && bits <= 64
      raise CAStruct::DefinitionError,
            "bit member requires bits: as an Integer in 1..64 (got #{bits.inspect})"
    end
    total_bit_offset = @offset * 8 + @bit_offset
    mem = Member.new(name.to_s, :bitfield,
                     {:bits       => bits,
                      :bit_offset => total_bit_offset,
                      :offset     => @offset})
    @members.push(mem)
    @bit_offset += bits
    while @bit_offset >= 8
      @offset += 1
      @bit_offset -= 8
    end
    if @align_max < 1
      @align_max = 1
    end
  end

  # @!visibility private
  VALID_ENDIAN = [:preserve, :native, :big, :little].freeze

  # Validate the `endian:` option on a typed-member declaration.
  # `allow` is false for non-numeric types (e.g. fixlen) where a
  # byte-swap view would mangle the value.
  def self.validate_endian! (opt, typename, allow)
    return unless opt.key?(:endian)
    unless allow
      raise CAStruct::DefinitionError,
            "endian: is not supported for #{typename} members"
    end
    unless VALID_ENDIAN.include?(opt[:endian])
      raise CAStruct::DefinitionError,
            "endian: must be one of #{VALID_ENDIAN.inspect} " \
            "(got #{opt[:endian].inspect})"
    end
  end

  [
   ["fixlen",   false],
   ["boolean",  true],
   ["int8",     true],
   ["uint8",    true],
   ["int16",    true],
   ["uint16",   true],
   ["int32",    true],
   ["uint32",   true],
   ["int64",    true],
   ["uint64",   true],
   ["float32",  true],
   ["float64",  true],
   ["cmplx64",  true],
   ["cmplx128", true],
  ].each do |typename, allow_endian|
    class_eval %{
      def #{typename} (*args)
        opt = args.last.is_a?(Hash) ? args.pop : {}
        if args.empty?
          raise CAStruct::DefinitionError,
                "#{typename} requires at least one member name " \
                "(use nil for anonymous padding)"
        end
        CAStruct::Builder.validate_endian!(opt, "#{typename}", #{allow_endian})
        args.each do |arg|
          member(:#{typename}, arg, opt)
        end
      end
    }
  end

  alias char_p   fixlen
  alias byte     uint8
  alias short    int16
  alias int      int32
  alias float    float32
  alias double   float64
  alias complex  cmplx64
  alias dcomplex cmplx128

end


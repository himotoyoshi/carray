#  Portable binary serialization ("_CARRAY3" format).
#
#  User-facing spec (C struct / FORTRAN / NumPy readers):
#  docs/topics/Serialization.md.
#
#  Public surface:
#    CArray.save(ca, path_or_io, endian: CArray.endian)
#    CArray.load(path_or_io_or_string)
#    CArray.dump(ca, endian: CArray.endian)   # -> String
#    CArray#marshal_dump / CArray#marshal_load
#
#  Core promise: numeric payload lives at a fixed offset (data_offset,
#  256 in v1.x) as raw contiguous bytes in a single file-wide endian.
#  A C / FORTRAN / Python reader reaches the data with one seek and
#  never parses any Ruby-specific metadata.  CArray-native concepts
#  (attribute Hash, data_class Face schema, mask) ride in a YAML
#  flow-style trailer at the file tail that other languages skip.
#
#  CA_OBJECT (arbitrary Ruby objects) is *not* serialisable by this
#  portable format: CArray.save raises on it.  Object arrays persist
#  through the separate Ruby-only Marshal path (CArray#marshal_dump).
#
# On-disk layout (all header integers in file endian; the byte order is
# self-describing via endian_marker at offset 8):
#
#   0-7      magic            char*8    "_CARRAY3"
#   8-11     endian_marker    uint32    0x01020304 in file endian
#   12       version_major    uint8     1
#   13       version_minor    uint8     0
#   14-15    header_bytes     uint16    256
#   16       has_mask         uint8
#   17       has_trailer      uint8
#   18       data_type_code   uint8     CArray CA_* code
#   19       ndim             uint8
#   20-23    reserved0        uint32    zero (align shape to 8 bytes)
#   24-151   shape            int64*16  front ndim slots valid
#   152-155  element_bytes    uint32
#   156-159  flags            int32     raw ca->flags snapshot (provenance)
#   160-167  elements         uint64
#   168-175  data_offset      uint64    = 256
#   176-183  data_bytes       uint64    = elements*element_bytes
#   184-191  mask_offset      uint64    0 if !has_mask
#   192-199  mask_bytes       uint64    0 if !has_mask
#   200-207  trailer_offset   uint64    0 if !has_trailer
#   208-215  trailer_bytes    uint64    0 if !has_trailer
#   216-223  data_checksum    uint64    reserved (0)
#   224      checksum_algo    uint8     reserved (0=none)
#   225-255  reserved         zero
#
#   256-...    Data     (raw contiguous, file endian ordering)
#   ...        Mask     (raw int8*elements, if has_mask)
#   ...        Trailer  (UTF-8 YAML flow, trailer_bytes long, if present)
#
#  flags is a verbatim snapshot of the source array's internal
#  ca->flags at write time, kept purely as a provenance record of what
#  the array was (scalar / Face / view / read-only / ...).  It is NOT
#  read back on load and carries no reconstruction meaning.

require "stringio"
require "psych"

class CArray::Serializer   # :nodoc:

  # @!visibility private
  MAGIC         = "_CARRAY3"
  # @!visibility private
  HEADER_BYTES  = 256
  # @!visibility private
  VERSION_MAJOR = 1
  # @!visibility private
  VERSION_MINOR = 0
  # @!visibility private
  ENDIAN_MARKER = 0x01020304

  # Canonical primitive-type notation for the trailer data_class
  # schema.  The .ca format *owns* this mapping: it is the same bare
  # PEP 3118 notation CArray's MemoryView layer emits via
  # ca_mv_format_for, frozen here as the format's own copy so a future
  # MemoryView producer flip does not silently change the on-disk spec.
  # Non-primitive member types (:fixlen / :object / nested class /
  # CArray template / :bitfield) are absent, so SYMBOL_TO_PEP[type] is
  # nil for them, which enforces the flat-primitive-only rule for free
  # (a non-expressible member raises on save).
  PEP_TO_SYMBOL = {
    "?"  => :boolean,
    "b"  => :int8,   "B" => :uint8,
    "h"  => :int16,  "H" => :uint16,
    "i"  => :int32,  "I" => :uint32,
    "q"  => :int64,  "Q" => :uint64,
    "f"  => :float32, "d" => :float64,
    "Zf" => :cmplx64, "Zd" => :cmplx128,
  }.freeze

  # @!visibility private
  SYMBOL_TO_PEP = PEP_TO_SYMBOL.invert.freeze

  # @overload initialize(io)
  #   Allocates a Serializer around `io`. A String is wrapped in a
  #   `StringIO`; anything else is used directly.
  #   @param io [IO, String] destination or source.
  def initialize (io)
    case io
    when String
      @io = StringIO.new(io)
    else
      @io = io
    end
  end

  # @overload save(ca, endian: CArray.endian)
  #   Writes `ca` to the wrapped IO in the _CARRAY3 portable format.
  #   The data region is raw contiguous bytes; attribute Hash and
  #   data_class schema (if any) ride in a YAML trailer at the tail.
  #   @param ca [CArray] array to write.
  #   @param opt [Hash] `:endian` forces the output byte order
  #     (defaults to the host's; a differing value swaps data + header).
  #   @return [CArray] `ca`.
  #   @raise [ArgumentError] when `ca` is a CA_OBJECT array (use
  #     `Marshal.dump(ca)` instead), or carries a data_class the
  #     v1.0 flat-primitive schema cannot express.
  def save (ca, **opt)
    if ca.data_type == :object
      raise ArgumentError,
            "CArray.save cannot serialise a CA_OBJECT array " \
            "(arbitrary Ruby objects have no portable representation); " \
            "use Marshal.dump(ca) for a Ruby-only round-trip"
    end

    file_endian = opt[:endian] || CArray.endian
    swap        = (file_endian != CArray.endian)

    elements     = ca.elements
    element_bytes = ca.bytes
    data_bytes   = elements * element_bytes
    has_mask     = ca.has_mask?

    # Trailer is present only when there is semantic content: an
    # attribute Hash or a data_class schema.  A plain numeric array
    # writes no trailer (both trailer fields zero), keeping the
    # C / FORTRAN reader path a header + raw data.
    trailer = build_trailer(ca)
    trailer_str = trailer.empty? ? nil : encode_trailer(trailer)

    data_offset    = HEADER_BYTES
    mask_offset    = has_mask ? data_offset + data_bytes : 0
    mask_bytes     = has_mask ? elements : 0
    tail_offset    = has_mask ? mask_offset + mask_bytes : data_offset + data_bytes
    trailer_offset = trailer_str ? tail_offset : 0
    trailer_bytes  = trailer_str ? trailer_str.bytesize : 0

    dim = ca.shape
    dim = dim + Array.new(CA_RANK_MAX - dim.size, 0)

    header = {
      has_mask:       has_mask ? 1 : 0,
      has_trailer:    trailer_str ? 1 : 0,
      data_type_code: CArray.data_type_code(ca.data_type),
      ndim:           ca.ndim,
      shape:          dim,
      element_bytes:  element_bytes,
      flags:          ca.flags,
      elements:       elements,
      data_offset:    data_offset,
      data_bytes:     data_bytes,
      mask_offset:    mask_offset,
      mask_bytes:     mask_bytes,
      trailer_offset: trailer_offset,
      trailer_bytes:  trailer_bytes,
    }

    @io.write(self.class.pack_header(header, file_endian))

    data_ca = swap ? ca.swap_bytes : ca
    data_ca.dump_binary(@io)

    if has_mask
      ca.mask.dump_binary(@io)   # int8, endian-neutral
    end

    @io.write(trailer_str) if trailer_str

    return ca
  end

  # @overload load(data_type: nil)
  #   Reads a _CARRAY3 payload from the wrapped IO and returns the
  #   reconstructed array, re-wrapping it through its recorded
  #   data_class when the trailer carries one.
  #   @param opt [Hash] `:data_type` overrides the element type for a
  #     bare `CA_FIXLEN` payload.
  #   @return [CArray]
  #   @raise [RuntimeError] on a bad magic string, corrupt header, or
  #     unsupported version.
  def load (**opt)
    buf = @io.read(HEADER_BYTES)
    unless buf && buf.bytesize == HEADER_BYTES
      raise "not a CArray binary data (truncated header)"
    end
    if buf[0, 8] != MAGIC
      raise "not a CArray binary data (bad magic)"
    end

    # The byte order is self-describing via endian_marker at offset 8:
    # the writer stored 0x01020304 in file order, so the raw bytes are
    # 01 02 03 04 on a big-endian file and 04 03 02 01 on a little-endian
    # one.  The leading byte alone decides; anything else is corrupt.
    case buf[8].ord
    when 0x01 then file_endian = CA_BIG_ENDIAN
    when 0x04 then file_endian = CA_LITTLE_ENDIAN
    else
      raise "corrupt CArray binary data (endian marker mismatch)"
    end
    h = self.class.unpack_header(buf, file_endian)

    if h[:endian_marker] != ENDIAN_MARKER
      raise "corrupt CArray binary data (endian marker mismatch)"
    end
    if h[:version_major] != VERSION_MAJOR
      raise "unsupported CArray binary version #{h[:version_major]}.#{h[:version_minor]}"
    end
    if h[:header_bytes] != HEADER_BYTES
      raise "unsupported CArray binary header size #{h[:header_bytes]}"
    end
    if h[:data_bytes] != h[:elements] * h[:element_bytes]
      raise "corrupt CArray binary data (data_bytes cross-check failed)"
    end

    swap      = (file_endian != CArray.endian)
    data_type = h[:data_type_code]
    ndim      = h[:ndim]
    dim       = h[:shape][0, ndim]
    bytes     = h[:element_bytes]

    if opt[:data_type] and data_type == CArray.data_type_code(CA_FIXLEN)
      data_type = opt[:data_type]
    end

    ca = CArray.new(data_type, dim, :bytes => bytes)
    ca.load_binary(@io)
    ca[] = ca.swap_bytes if swap

    if h[:has_mask] != 0
      ca.mask = 0
      ca.mask.load_binary(@io)
    end

    if h[:trailer_bytes] > 0
      trailer_raw = @io.read(h[:trailer_bytes])
      trailer = decode_trailer(trailer_raw)
      ca = apply_trailer(ca, trailer)
    end

    return ca
  end

  private

  # Build the trailer mapping (String-keyed) from the array's
  # attributes and data_class.  Returns {} when there is nothing to
  # serialise.
  def build_trailer (ca)
    trailer = {}
    attrs = ca.attrs                 # frozen, merged along parent chain
    trailer["attrs"] = attrs unless attrs.empty?
    if ca.has_data_class? and ca.data_class
      trailer["data_class"] = build_data_class_schema(ca.data_class)
    end
    trailer
  end

  # Layer 1 (always) + Layer 2 `name` (when the class is named).
  # ruby_marshal_b64 (full-identity round-trip of anonymous / dynamic
  # classes) is deferred past v1.0 — anonymous classes round-trip via
  # Layer 1 synthesis on load (duck-typed, identity not preserved),
  # matching the "data_class identity out of scope for 3.0" pin.
  def build_data_class_schema (klass)
    members = klass.fields.map do |f|
      if f.bitfield?
        raise ArgumentError,
              "CArray.save cannot serialise data_class #{klass.inspect}: " \
              "member #{f.name.inspect} is a bitfield (the v1.0 Layer 1 " \
              "schema is flat-primitive only); use Marshal.dump(ca)"
      end
      pep = SYMBOL_TO_PEP[f.type]
      unless pep
        raise ArgumentError,
              "CArray.save cannot serialise data_class #{klass.inspect}: " \
              "member #{f.name.inspect} has non-primitive type #{f.type.inspect} " \
              "(nested struct / template / fixlen are not expressible in the " \
              "v1.0 Layer 1 schema); use Marshal.dump(ca)"
      end
      { "name" => f.name, "type" => pep, "offset" => f.offset, "bytes" => f.bytes }
    end

    schema = {
      "kind"         => (klass < CAUnion ? "union" : "struct"),
      "record_bytes" => klass::DATA_SIZE,
      "members"      => members,
    }
    schema["name"] = klass.name if klass.name
    schema
  end

  # Reconstruct attribute Hash + data_class wrapping from a parsed
  # trailer.  Returns the (possibly re-wrapped) array.
  def apply_trailer (ca, trailer)
    if trailer.key?("data_class")
      ca = wrap_data_class(ca, trailer["data_class"])
    end
    if trailer.key?("attrs")
      attrs = trailer["attrs"]
      if attrs.is_a?(Hash) and not attrs.empty?
        ca.instance_variable_set(:@attr, attrs)
      end
    end
    ca
  end

  # Load fall-through: prefer the named Ruby class (const_get), else
  # synthesise an anonymous struct from the Layer 1 members[], else
  # leave the raw CA_FIXLEN array untouched.
  def wrap_data_class (ca, schema)
    name = schema["name"]
    if name
      begin
        klass = Kernel.const_get(name)
      rescue NameError
        klass = nil
      end
      if klass and CArray.data_class?(klass)
        return CARecord.wrap(ca, klass)
      end
    end

    members = schema["members"]
    if members.is_a?(Array) and not members.empty?
      klass = synthesize_data_class(schema)
      return CARecord.wrap(ca, klass)
    end

    ca
  end

  # Build a runtime-defined CArray.struct / .union that reproduces the
  # exact byte layout described by the Layer 1 schema (explicit offsets
  # + total size so trailing padding is preserved).
  def synthesize_data_class (schema)
    members      = schema["members"]
    record_bytes = schema["record_bytes"]
    builder      = (schema["kind"] == "union") ? CArray.method(:union) : CArray.method(:struct)
    builder.call(:pack => 1, :size => record_bytes) do
      members.each do |m|
        sym = PEP_TO_SYMBOL[m["type"]]
        unless sym
          raise "unknown data_class member type #{m["type"].inspect} in CArray binary data"
        end
        member sym, m["name"], :offset => m["offset"]
      end
    end
  end

  # YAML flow-style emission.  Reads like a JSON one-liner but with
  # native non-finite Float literals (.inf / .nan).
  def encode_trailer (trailer)
    visitor = Psych::Visitors::YAMLTree.create
    visitor << trailer
    ast = visitor.tree
    ast.grep(Psych::Nodes::Mapping).each  { |n| n.style = Psych::Nodes::Mapping::FLOW }
    ast.grep(Psych::Nodes::Sequence).each { |n| n.style = Psych::Nodes::Sequence::FLOW }
    # line_width: -1 disables the emitter's line folding so the flow
    # trailer stays a single line regardless of length.
    ast.yaml(nil, :line_width => -1).sub(/\A---\s*/, "").strip.b
  end

  # safe_load is the symmetric guardrail: it restores the
  # JSON-compatible value set + non-finite Floats and refuses any
  # `!ruby/object:` tag, so a hostile trailer cannot execute code.
  def decode_trailer (raw)
    Psych.safe_load(raw, :permitted_classes => [], :aliases => false) || {}
  end

  class << self

    # Pack a header field Hash into a HEADER_BYTES buffer, integers in
    # `file_endian` byte order.
    def pack_header (h, file_endian)
      e     = (file_endian == CA_LITTLE_ENDIAN) ? "<" : ">"
      shape = h[:shape]
      body = [
        MAGIC,               # a8   0
        ENDIAN_MARKER,       # L    8
        VERSION_MAJOR,       # C    12
        VERSION_MINOR,       # C    13
        HEADER_BYTES,        # S    14
        h[:has_mask],        # C    16
        h[:has_trailer],     # C    17
        h[:data_type_code],  # C    18
        h[:ndim],            # C    19
        0,                   # L    20  reserved0
        *shape,              # q16  24
        h[:element_bytes],   # L    152
        h[:flags],           # l    156
        h[:elements],        # Q    160
        h[:data_offset],     # Q    168
        h[:data_bytes],      # Q    176
        h[:mask_offset],     # Q    184
        h[:mask_bytes],      # Q    192
        h[:trailer_offset],  # Q    200
        h[:trailer_bytes],   # Q    208
        0,                   # Q    216  data_checksum
        0,                   # C    224  checksum_algo
      ].pack("a8L#{e}CCS#{e}CCCCL#{e}q#{e}16L#{e}l#{e}Q#{e}Q#{e}Q#{e}Q#{e}Q#{e}Q#{e}Q#{e}Q#{e}C")
      body.ljust(HEADER_BYTES, "\x00")
    end

    # Parse a HEADER_BYTES buffer (integers in `file_endian`) into a
    # field Hash.  Byte-slice unpack mirrors the C struct offsets.
    def unpack_header (buf, file_endian)
      e = (file_endian == CA_LITTLE_ENDIAN) ? "<" : ">"
      {
        endian_marker:  buf[8, 4].unpack1("L#{e}"),
        version_major:  buf[12].ord,
        version_minor:  buf[13].ord,
        header_bytes:   buf[14, 2].unpack1("S#{e}"),
        has_mask:       buf[16].ord,
        has_trailer:    buf[17].ord,
        data_type_code: buf[18].ord,
        ndim:           buf[19].ord,
        shape:          buf[24, 128].unpack("q#{e}16"),
        element_bytes:  buf[152, 4].unpack1("L#{e}"),
        flags:          buf[156, 4].unpack1("l#{e}"),
        elements:       buf[160, 8].unpack1("Q#{e}"),
        data_offset:    buf[168, 8].unpack1("Q#{e}"),
        data_bytes:     buf[176, 8].unpack1("Q#{e}"),
        mask_offset:    buf[184, 8].unpack1("Q#{e}"),
        mask_bytes:     buf[192, 8].unpack1("Q#{e}"),
        trailer_offset: buf[200, 8].unpack1("Q#{e}"),
        trailer_bytes:  buf[208, 8].unpack1("Q#{e}"),
        data_checksum:  buf[216, 8].unpack1("Q#{e}"),
        checksum_algo:  buf[224].ord,
      }
    end

  end

end

class CArray

  # @overload save(ca, output, **opt)
  #   Writes `ca` to `output` in the _CARRAY3 portable format. A
  #   String `output` is opened as a binary file; anything else is
  #   treated as an IO-like object.
  #   @param ca [CArray] array to write.
  #   @param output [String, IO] destination path or IO.
  #   @param opt [Hash] serializer options (`:endian`).
  #   @return [CArray] `ca`.
  def self.save (ca, output, **opt)
    case output
    when String
      open(output, "wb:ASCII-8BIT") { |io|
        return Serializer.new(io).save(ca, **opt)
      }
    else
      return Serializer.new(output).save(ca, **opt)
    end
  end

  # @overload load(input, **opt)
  #   Reads a _CARRAY3 payload from `input`. A String starting with
  #   the CArray magic is decoded in place; other Strings are treated
  #   as file paths; anything else is used as IO.
  #   @param input [String, IO] source path, in-memory payload, or IO.
  #   @param opt [Hash] loader options (`:data_type`).
  #   @return [CArray]
  def self.load (input, **opt)
    case input
    when String
      if input.bytesize >= Serializer::HEADER_BYTES and
         input.byteslice(0, 8) == Serializer::MAGIC
        io = StringIO.new(input)
        return Serializer.new(io).load(**opt)
      else
        open(input, "rb:ASCII-8BIT") { |io|
          return Serializer.new(io).load(**opt)
        }
      end
    else
      return Serializer.new(input).load(**opt)
    end
  end

  # @overload dump(ca, **opt)
  #   Returns `ca` serialized to a String in the _CARRAY3 format.
  #   @param ca [CArray] array to serialize.
  #   @param opt [Hash] serializer options (`:endian`).
  #   @return [String]
  def self.dump (ca, **opt)
    io = StringIO.new("".b)
    Serializer.new(io).save(ca, **opt)
    return io.string
  end

  # for Marshal
  #
  # Decision 4: the Marshal path and the portable format are
  # separated.  A CA_OBJECT array Marshal-dumps its element VALUEs
  # directly (Ruby-only, no portability promise); every other array
  # reuses the portable format as a numeric container.  So
  # Marshal.dump works for object arrays even though CArray.save
  # refuses them.

  # @overload marshal_dump
  #   Returns the Marshal payload for `self`. Virtual / wrapped
  #   arrays are copied first so the payload always describes an
  #   owning array.
  #   @return [Array]
  def marshal_dump ()
    target = (self.class != CArray and self.class != CScalar) ? self.copy : self
    if target.data_type == :object
      ["object",
       target.shape,
       target.value.to_a,
       (target.has_mask? ? target.mask.to_a : nil)]
    else
      ["portable", CArray.dump(target)]
    end
  end

  # @overload marshal_load(data)
  #   Reconstitutes `self` from a Marshal payload produced by
  #   {#marshal_dump}.
  #   @param data [Array] Marshal payload.
  #   @return [void]
  def marshal_load (data)
    tag, *rest = data
    case tag
    when "object"
      shape, values, mask = rest
      ca = CArray.object(*shape)
      ca[] = values
      if mask
        ca.mask = 0
        ca.mask[] = mask
      end
      initialize_copy(ca)
    when "portable"
      ca = CArray.load(StringIO.new(rest[0]))
      initialize_copy(ca)
    else
      raise TypeError, "unrecognised CArray Marshal payload"
    end
  end

end

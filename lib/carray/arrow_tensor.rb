# Apache Arrow "tensor IPC" reader / writer for CArray.  [experimental]
#
# This surface is experimental: the method names, the module namespace, and
# the packaging (it may later be extracted into a standalone, array-library-
# neutral gem) are not yet frozen and may change in a future release.
#
# This is an interoperability layer, not an archival format: it exchanges
# a dense numeric array with the Arrow ecosystem (pyarrow.ipc.write_tensor /
# read_tensor and equivalents) using Arrow's encapsulated tensor message.
# For faithful, reproducible persistence of a CArray -- mask, attributes,
# data_class and all -- use CArray.save / CArray.load (the _CARRAY3 format).
#
# The on-disk shape is: a 0xFFFFFFFF continuation marker, an int32 metadata
# length, a FlatBuffers Message whose header is a Tensor (element type, shape,
# byte strides, and a Buffer descriptor), padding to an 8-byte boundary, then
# the raw contiguous element bytes.  Only the numeric types Arrow tensors
# admit are supported (int8..int64, uint8..uint64, float32, float64); boolean,
# complex, fixlen and object arrays have no Arrow tensor representation and are
# rejected.  A masked CArray is rejected too, mirroring the MemoryView policy:
# Arrow tensors carry no validity concept, so the caller must be explicit
# (ca.value to drop the mask, ca.unmask_copy(fill) to bake it in, or persist
# the mask separately through CArray.save).

require "stringio"

class CArray
  # Reader / writer for Arrow's encapsulated tensor IPC message, for
  # exchanging a dense numeric array with the Arrow ecosystem
  # (`pyarrow.ipc.write_tensor` / `read_tensor` and equivalents).
  #
  # Experimental: the method names, this namespace and the packaging are not
  # frozen, and the layer may later move to a standalone, array-library-neutral
  # gem.  It is an interoperability format, not an archival one — an Arrow
  # tensor carries no mask, attributes or data_class, so `CArray.save` /
  # `CArray.load` remain the way to persist a CArray faithfully.
  #
  # Only the numeric types an Arrow tensor admits are supported (int8..int64,
  # uint8..uint64, float32, float64).  Boolean, complex, fixlen and object
  # arrays are rejected, as is a masked array — Arrow tensors have no validity
  # concept, so the caller must be explicit (`ca.value` to drop the mask,
  # `ca.unmask_copy(fill)` to bake it in, or save the mask separately).
  module ArrowTensor

    # CArray data_type symbol -> Arrow element-type descriptor.
    #   [:float, precision]  precision: 1 = single, 2 = double
    #   [:int, bit_width, signed?]
    DTYPE_TO_ARROW = {
      float32: [:float, 1], float64: [:float, 2],
      int8:  [:int, 8,  true],  int16: [:int, 16, true],
      int32: [:int, 32, true],  int64: [:int, 64, true],
      uint8: [:int, 8,  false], uint16:[:int, 16, false],
      uint32:[:int, 32, false], uint64:[:int, 64, false],
    }.freeze

    module_function

    # Write +ca+ to +io+ as an Arrow tensor IPC message.
    def write (ca, io)
      if ca.has_mask?
        raise ArgumentError,
              "cannot write a masked CArray as an Arrow tensor " \
              "(Arrow tensors have no validity concept); pass ca.value to " \
              "drop the mask, ca.unmask_copy(fill) to fill it, or use " \
              "CArray.save for a mask-preserving round-trip"
      end
      arrow = DTYPE_TO_ARROW[ca.data_type]
      unless arrow
        raise ArgumentError,
              "cannot write a #{ca.data_type} CArray as an Arrow tensor " \
              "(Arrow tensors are numeric only: int8..int64, uint8..uint64, " \
              "float32, float64)"
      end
      raise ArgumentError, "cannot write a 0-dimensional array" if ca.ndim < 1

      shape   = ca.shape
      elt     = ca.bytes
      strides = row_major_strides(shape, elt)

      body = StringIO.new("".b)
      ca.dump_binary(body)          # raw contiguous element bytes, row-major
      body = body.string

      meta = build_metadata(arrow, shape, strides, body.bytesize)
      pad  = (8 - ((8 + meta.bytesize) % 8)) % 8
      meta += "\0".b * pad

      io.write([0xFFFFFFFF].pack("V"))
      io.write([meta.bytesize].pack("l<"))
      io.write(meta)
      io.write(body)
      ca
    end

    # Read an Arrow tensor IPC message from +io+ and return a new CArray.
    def read (io)
      b = io.respond_to?(:read) ? io.read : io.to_s
      b = b.b
      meta = parse_metadata(b)
      type = meta[:data_type]
      unless CArray.respond_to?(:data_type_code) && DTYPE_TO_ARROW.key?(type)
        raise ArgumentError,
              "Arrow tensor element type #{type.inspect} has no CArray " \
              "counterpart"
      end
      build_carray(type, meta[:shape], meta[:strides], meta[:body])
    end

    # ---- helpers ----------------------------------------------------------

    def row_major_strides (shape, elt)
      s = Array.new(shape.length)
      acc = elt
      (shape.length - 1).downto(0) do |i|
        s[i] = acc
        acc *= shape[i]
      end
      s
    end
    private_class_method :row_major_strides

    def build_carray (type, shape, strides, body)
      elt   = CArray.new(type, [1]).bytes
      rmaj  = row_major_strides(shape, elt)
      if strides == rmaj
        ca = CArray.new(type, shape)
        ca.load_binary(StringIO.new(body))
        return ca
      end
      cmaj = row_major_strides(shape.reverse, elt).reverse
      if strides == cmaj
        t = CArray.new(type, shape.reverse)
        t.load_binary(StringIO.new(body))
        return t.transpose(*(0...shape.length).to_a.reverse).to_ca
      end
      # General strided layout (rare): gather element by element.
      gather_strided(type, shape, strides, body)
    end
    private_class_method :build_carray

    def gather_strided (type, shape, strides, body)
      elt  = CArray.new(type, [1]).bytes
      code = UNPACK[type]
      ca   = CArray.new(type, shape)
      elements = shape.inject(1, :*)
      idx = Array.new(shape.length, 0)
      elements.times do
        off = 0
        idx.each_with_index { |v, k| off += v * strides[k] }
        ca[*idx] = body[off, elt].unpack1(code)
        k = shape.length - 1
        while k >= 0
          idx[k] += 1
          break if idx[k] < shape[k]
          idx[k] = 0
          k -= 1
        end
      end
      ca
    end
    private_class_method :gather_strided

    # @!visibility private
    UNPACK = {
      float32:"e", float64:"E",
      int8:"c", int16:"s<", int32:"l<", int64:"q<",
      uint8:"C", uint16:"v", uint32:"V", uint64:"Q<",
    }.freeze

    # ---- FlatBuffers Message encoder (header = Tensor) --------------------

    # Minimal back-to-front FlatBuffers builder, specialised to the fields the
    # Tensor message uses (scalars, tables, vectors, one inline struct).
    #
    # @!visibility private
    class Builder
      def initialize
        @buf = "".b
        @minalign = 1
        @vt = nil
        @obj_start = nil
      end

      # @!visibility private
      def offset; @buf.bytesize; end

      # @!visibility private
      def prep (size, additional)
        @minalign = size if size > @minalign
        align = ((~(@buf.bytesize + additional)) + 1) & (size - 1)
        @buf.prepend("\0".b * align) if align > 0
      end

      # @!visibility private
      def u8 (x);  @buf.prepend([x].pack("C"));  end
      # @!visibility private
      def i16 (x); @buf.prepend([x].pack("s<")); end
      # @!visibility private
      def u16 (x); @buf.prepend([x].pack("v"));  end
      # @!visibility private
      def u32 (x); @buf.prepend([x].pack("V"));  end
      # @!visibility private
      def i32 (x); @buf.prepend([x].pack("l<")); end
      # @!visibility private
      def i64 (x); @buf.prepend([x].pack("q<")); end

      # @!visibility private
      def uoffset (off)
        prep(4, 0)
        u32(offset() - off + 4)
      end

      # @!visibility private
      def slot (v); @vt[v] = offset(); end

      # @!visibility private
      def slot_i16 (v, x); prep(2,0); i16(x); slot(v); end
      # @!visibility private
      def slot_u8  (v, x); prep(1,0); u8(x);  slot(v); end
      # @!visibility private
      def slot_i32 (v, x); prep(4,0); i32(x); slot(v); end
      # @!visibility private
      def slot_i64 (v, x); prep(8,0); i64(x); slot(v); end
      # @!visibility private
      def slot_bool(v, x); prep(1,0); u8(x ? 1 : 0); slot(v); end
      # @!visibility private
      def slot_uoffset (v, off); uoffset(off); slot(v); end

      # @!visibility private
      def start_object (n); @vt = Array.new(n, 0); @obj_start = offset(); end

      # @!visibility private
      def end_object
        prep(4, 0)
        i32(0)                       # soffset placeholder
        obj = offset()
        n = @vt.length
        n -= 1 while n > 0 && @vt[n-1] == 0
        (n-1).downto(0) do |i|
          u16(@vt[i] == 0 ? 0 : (obj - @vt[i]))
        end
        u16(obj - @obj_start)        # referenced table size
        u16((n + 2) * 2)             # vtable size
        soff = offset() - obj
        @buf[@buf.bytesize - obj, 4] = [soff].pack("l<")
        obj
      end

      # @!visibility private
      def start_vector (elem, count, align); prep(4, elem*count); prep(align, elem*count); end
      # @!visibility private
      def end_vector (count); u32(count); offset(); end

      # @!visibility private
      def finish (root)
        prep(@minalign, 4)
        uoffset(root)
        @buf
      end
    end

    def build_metadata (arrow, shape, strides, body_len)
      fb = Builder.new
      tag = arrow[0] == :float ? 3 : 2

      type_off =
        if arrow[0] == :float
          fb.start_object(1)
          fb.slot_i16(0, arrow[1])            # precision
          fb.end_object
        else
          fb.start_object(2)
          fb.slot_i32(0, arrow[1])            # bitWidth
          fb.slot_bool(1, arrow[2])           # is_signed
          fb.end_object
        end

      dim_offs = shape.map do |sz|
        fb.start_object(2)
        fb.slot_i64(0, sz)                     # TensorDim.size (name omitted)
        fb.end_object
      end
      fb.start_vector(4, dim_offs.length, 4)
      dim_offs.reverse_each { |o| fb.uoffset(o) }
      shape_vec = fb.end_vector(dim_offs.length)

      fb.start_vector(8, strides.length, 8)
      strides.reverse_each { |s| fb.i64(s) }
      strides_vec = fb.end_vector(strides.length)

      fb.start_object(5)                       # Tensor: type_type,type,shape,strides,data
      fb.prep(8, 16)                           # data: inline Buffer struct
      fb.i64(body_len)                         #   length
      fb.i64(0)                                #   offset
      fb.slot(4)
      fb.slot_uoffset(3, strides_vec)
      fb.slot_uoffset(2, shape_vec)
      fb.slot_uoffset(1, type_off)
      fb.slot_u8(0, tag)                       # type_type
      tensor_off = fb.end_object

      fb.start_object(5)                       # Message: version,header_type,header,bodyLength,custom
      fb.slot_i64(3, body_len)
      fb.slot_uoffset(2, tensor_off)
      fb.slot_u8(1, 4)                         # header_type = Tensor
      fb.slot_i16(0, 4)                        # metadata version V5
      msg_off = fb.end_object

      fb.finish(msg_off)
    end
    private_class_method :build_metadata

    # ---- FlatBuffers Message decoder --------------------------------------

    def parse_metadata (b)
      u16 = ->(o){ b[o,2].unpack1("v") }
      i32 = ->(o){ b[o,4].unpack1("l<") }
      u32 = ->(o){ b[o,4].unpack1("V") }
      i64 = ->(o){ b[o,8].unpack1("q<") }
      field = ->(t,f){ vt = t - i32.(t); vts = u16.(vt); slot = 4 + f*2
                       next 0 if slot >= vts; vo = u16.(vt+slot); vo==0 ? 0 : t+vo }
      deref = ->(pos){ pos + u32.(pos) }

      raise ArgumentError, "not an Arrow IPC message" unless u32.(0) == 0xffffffff
      meta_len = i32.(4)
      fb = 8
      body_off = 8 + meta_len

      msg = fb + i32.(fb)
      htag = (p = field.(msg,1); p == 0 ? 0 : b.getbyte(p))
      raise ArgumentError, "not a tensor message" unless htag == 4
      hpos = deref.(field.(msg,2))

      type_tag = b.getbyte(field.(hpos,0))
      type_tbl = deref.(field.(hpos,1))
      shp_vec  = deref.(field.(hpos,2)); n = u32.(shp_vec)
      shape = (0...n).map { |i| dp = deref.(shp_vec + 4 + i*4); i64.(field.(dp,0)) }
      sv_slot = field.(hpos,3)
      strides =
        if sv_slot == 0
          row_major_strides(shape, CArray.new(arrow_symbol(type_tag, type_tbl, u16, i32, b), [1]).bytes)
        else
          sv = deref.(sv_slot); m = u32.(sv); (0...m).map { |i| i64.(sv + 4 + i*8) }
        end
      dpos = field.(hpos,4)
      data_off = i64.(dpos); data_len = i64.(dpos+8)

      { data_type: arrow_symbol(type_tag, type_tbl, u16, i32, b),
        shape: shape, strides: strides,
        body: b[body_off + data_off, data_len] }
    end
    private_class_method :parse_metadata

    def arrow_symbol (tag, tbl, u16, i32, b)
      case tag
      when 3
        { 0=>:float16, 1=>:float32, 2=>:float64 }[u16.(tbl_field(tbl, 0, i32, u16))] ||
          (raise ArgumentError, "unsupported Arrow float precision")
      when 2
        bw = i32.(tbl_field(tbl, 0, i32, u16))
        sf = tbl_field(tbl, 1, i32, u16)
        signed = sf == 0 ? false : (b.getbyte(sf) != 0)  # is_signed FlatBuffers default = false
        (signed ? "int#{bw}" : "uint#{bw}").to_sym
      else
        raise ArgumentError, "unsupported Arrow tensor element type (tag=#{tag})"
      end
    end
    private_class_method :arrow_symbol

    def tbl_field (t, f, i32, u16)
      vt = t - i32.(t); vts = u16.(vt); slot = 4 + f*2
      return 0 if slot >= vts
      vo = u16.(vt + slot); vo == 0 ? 0 : t + vo
    end
    private_class_method :tbl_field

  end

  # Reads an Arrow tensor IPC file and returns it as a new CArray.
  #
  # Experimental, and the name is provisional.
  #
  # @param filename [String] path to the message.
  # @return [CArray]
  # @see ArrowTensor
  def self.load_arrow_tensor (filename)
    File.open(filename, "rb") { |io| ArrowTensor.read(io) }
  end

  # Writes `self` to `filename` as an Arrow tensor IPC message.
  #
  # Experimental, and the name is provisional.  Rejects a masked or
  # non-numeric array; see {ArrowTensor} for the type policy.
  #
  # @param filename [String] path to write.
  # @return [self]
  # @see ArrowTensor
  def save_arrow_tensor (filename)
    File.open(filename, "wb") { |io| ArrowTensor.write(self, io) }
    self
  end
end

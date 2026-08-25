# The data class for fixed length carray are required to satisfy only
# five conditions.
#
#   * constant data_class::DATA_SIZE    -> integer
#   * constant data_class::MEMBER_TABLE -> hash
#   * constant data_class::MEMBERS      -> array (MEMBER_TABLE.keys as usual)
#   * method   data_class.decode(data)  -> new data_class object
#   * method   data_class#encode()      -> string 
#
# The implementation of other properties (cf. initialization, instance,
# methods ...) are left free.
#
# CAStruct and CAUnion are examples of such data class.
#
# option = {
#   :pack => 1,   # nil for alignment, int for pack(n)
#   :size => 1024 # user defined size (with padding)
# }
# 
# CArray.struct(option) { |s|
# 
#   # numeric types
# 
#   int8   :a, :b, :c
# 
#   float32   :f1, :f2
#   float     :f5, :f6
# 
#   float64   :d1, :d2
#   double    :d5, :d6
# 
#   # fixed length or string
# 
#   fixlen :str1, :str2, :bytes => 3
#   char_p :str3, :str4, :bytes => 3
# 
#   # array type
#   array  :ary1, :ary2, :type => CArray.int(3)
#
#   # struct type
#   struct(:st1, :st2) { uint8 :a, :b, :c }
#   struct :st3, :st4, :type => CArray.struct { uint8 :a, :b, :c }
# 
#   # union type
#   union(:un1, :un2) { uint8 :a; int16 :b; float32 :c }
#   union :un3, :un4, :type => CArray.union { uint8 :a, :b, :c }
# 
#   # anonymous
# 
#   int8_t nil, nil, nil
#   fixlen nil, :bytes=>3   ### padding
#
#   # low level definition
#   member CA_INT8, :x0
#   member :int8, :mem0, :mem1
#   member "int8", :mem0, :mem1
#   member :uint8, nil            ### anonymous
#   member CArray.int(3), :ary3
#   member struct{ int8 :a, :b, :c }, :st5, :st6
#   member union{ int8 :a; int16 :b; float :c }, :st5, :st6
#
# }

class CAStruct
  # CAStruct::Builder is the DSL backend behind CArray.struct / CArray.union.
  # It is only touched at struct-definition time (= the body of a
  # `CArray.struct { ... }` block); programs that only consume pre-defined
  # struct classes never reference it.  Lazy-load on first lookup.
  autoload :Builder, "carray/struct_builder"

  # Generic base for all CAStruct-related errors.  Callers can rescue
  # this class to catch any struct-side failure regardless of which
  # specific sub-error fired.
  class Error < StandardError; end

  # Raised by CAStruct::Builder when the struct/union definition is
  # malformed (duplicate member name, empty typed-method call, etc.).
  class DefinitionError < Error; end

  # Raised by CAStruct#decode / #encode when the input cannot be
  # interpreted as the struct's binary representation.
  class DecodeError < Error; end

  # Reflection record for a single struct member.  Frozen by default
  # so callers can treat it as a value object.  Lifted from
  # `MEMBER_TABLE`'s `[offset, type, opts]` tuple to give first-class
  # access to member metadata without exposing the opaque hash shape.
  #
  # Two flavours:
  #
  # - Regular byte-typed member: `name` / `offset` / `type` / `bytes`
  #   describe the placement.  For typed primitives, `type` is the
  #   Symbol (`:int32` etc.); for nested CAStruct subclass members,
  #   `type` is the class; for CArray-template members, `type` is the
  #   template CArray.
  # - Bit member: `bitfield?` returns true; `bits` and
  #   `bit_offset` hold the bit-level placement.  `offset` is the
  #   byte containing the LSB of the field (for raw-record indexing),
  #   `bytes` is nil.
  class Field
    attr_reader :name, :offset, :type, :bytes, :bits, :bit_offset, :endian

    def initialize (name:, offset:, type:, bytes: nil,
                    bits: nil, bit_offset: nil, endian: nil)
      @name       = name
      @offset     = offset
      @type       = type
      @bytes      = bytes
      @bits       = bits
      @bit_offset = bit_offset
      @endian     = endian
      freeze
    end

    def bitfield?
      @type == :bitfield
    end

    # @return [String]
    def inspect
      if bitfield?
        format("#<%s %p bitfield bits=%d bit_offset=%d>",
               self.class, @name, @bits, @bit_offset)
      else
        endian_part = @endian ? format(" endian=%p", @endian) : ""
        format("#<%s %p type=%p offset=%d bytes=%s%s>",
               self.class, @name, @type, @offset, @bytes.inspect,
               endian_part)
      end
    end

    alias to_s inspect

    # Field-wise comparison of the member's declaration (name, offset, type,
    # width, bit placement, endianness).  Aliased as `eql?`.
    # @return [Boolean]
    def == (other)
      other.is_a?(Field)        &&
        @name       == other.name &&
        @offset     == other.offset &&
        @type       == other.type &&
        @bytes      == other.bytes &&
        @bits       == other.bits &&
        @bit_offset == other.bit_offset &&
        @endian     == other.endian
    end

    alias eql? ==

    # @return [Integer] a hash consistent with #==.
    def hash
      [@name, @offset, @type, @bytes, @bits, @bit_offset, @endian].hash
    end
  end

end

class CArray

  # @overload st
  #   Returns a Ruby `Struct` view exposing every {CAStruct} member
  #   of `self` as a `Struct` attribute holding the corresponding
  #   member column. Cached per receiver.
  #   @return [Struct]
  #   @raise [CAStruct::Error] when `self` has no `data_class`.
  def st
    unless has_data_class?
      raise CAStruct::Error, "carray does not have a data_class"
    end
    unless @struct
      struct_class = Struct.new(nil, *data_class::MEMBERS)
      members = data_class::MEMBERS.map{|name| self[name]}
      @struct = struct_class.new(*members)
    end
    return @struct
  end

end

class CAStruct

  include Enumerable

  class << self
    
    # @return [String] the struct's name, or `"AnonStruct"` when it was
    #   defined anonymously.
    def inspect
      return name.nil? ? "AnonStruct" : name
    end
    
    # @overload [](*values)
    #   Returns a new struct record whose members are set from
    #   `values` in declaration order. Missing values leave the
    #   corresponding member at its default; extra values raise.
    #   @param values [Array<Object>]
    #   @return [CAStruct]
    #   @raise [ArgumentError] when too many values are given.
    def [] (*argv)
      if argv.size > self::MEMBERS.size
        raise ArgumentError,
              format("too many arguments for %s.[] (<%i> for <%i>)",
                     inspect, argv.size, self::MEMBERS.size)
      end
      obj = new()
      members.each do |name|
        break if argv.empty?
        obj[name] = argv.shift
      end
      return obj
    end
    
    # @overload members
    #   Returns the member name list in declaration order.
    #   @return [Array<String>]
    def members
      return self::MEMBERS
    end

    # @overload fields
    #   Returns the struct's members as {CAStruct::Field} objects
    #   in declaration order. Cached on the class.
    #   @return [Array<CAStruct::Field>]
    def fields
      @__fields__ ||= self::MEMBERS.map { |name|
        offset, type, opts = *self::MEMBER_TABLE[name]
        opts ||= {}
        if type == :bitfield
          CAStruct::Field.new(name:       name,
                              offset:     offset,
                              type:       :bitfield,
                              bits:       opts[:bits],
                              bit_offset: opts[:bit_offset])
        else
          CAStruct::Field.new(name:   name,
                              offset: offset,
                              type:   type,
                              bytes:  opts[:bytes],
                              endian: opts[:endian])
        end
      }.freeze
    end

    # @overload field_info(name)
    #   Returns the {CAStruct::Field} for `name`, or `nil` when the
    #   member is unknown.
    #   @param name [Symbol, String]
    #   @return [CAStruct::Field, nil]
    def field_info (name)
      key = name.to_s
      fields.find { |f| f.name == key }
    end

    # @overload offset_of(name)
    #   Returns the offset of member `name`: bytes for regular
    #   members, bits for bit members. `nil` when the member is
    #   unknown.
    #   @param name [Symbol, String]
    #   @return [Integer, nil]
    def offset_of (name)
      f = field_info(name)
      return nil unless f
      f.bitfield? ? f.bit_offset : f.offset
    end

    # @overload decode(data)
    #   Returns a new struct record built from the binary `data`
    #   (String or CArray).
    #   @param data [String, CArray]
    #   @return [CAStruct]
    def decode (data)                        ### required element as data class
      return new.decode(data)
    end

    # @overload size
    #   Returns the byte size of the struct's layout.
    #   @return [Integer]
    def size
      return self::DATA_SIZE
    end

  end

  # @overload initialize(*values)
  #   Allocates a new struct record. Members are set from the
  #   trailing positional `values` in declaration order, or from a
  #   single Hash argument keyed by member name.
  #   @param values [Array<Object>, Array<Hash>]
  #   @raise [ArgumentError] on unknown Hash keys or an excess of
  #     positional values.
  def initialize (*argv)
    @data = CScalar.new(self.class)
    mems = members
    if argv.size == 1 and argv.first.is_a?(Hash)
      # Validate keys up-front so the caller gets one clear error
      # listing all unknown keys, rather than a NoMethodError from the
      # first one and silent partial-init for the rest.
      known   = self.class::MEMBER_TABLE
      unknown = argv.first.keys.reject { |k| known.key?(k.to_s) }
      unless unknown.empty?
        raise ArgumentError,
              format("unknown member(s) for %s: %s (known: %s)",
                     self.class.inspect,
                     unknown.map(&:inspect).join(", "),
                     mems.map(&:inspect).join(", "))
      end
      argv.first.each do |k, v|
        self[k] = v
      end
    elsif argv.size <= mems.size
      argv.each_with_index do |v, i|
        self[mems[i]] = v
      end
    else
      raise ArgumentError,
            format("too many arguments for %s.new (<%i> for <%i>)",
                   self.class.inspect, argv.size, mems.size)
    end
  end

  protected

  def __data__
    @data
  end

  public

  # Member access (`record[:name]` / `record["name"]` / `record[i]`).
  # Step 3 (3.0): the per-type `case` was replaced by a class-level
  # DISPATCH_TABLE built once at struct-definition time.  Each known
  # member has a frozen `[reader_proc, writer_proc]` pair that closes
  # over its offset / type / opts, so the per-call work is one Hash
  # lookup + one Proc#call.  Unknown names fall back to `send(name)`
  # so subclasses can define computed members via plain Ruby methods.
  # @overload [](name)
  #   Returns the value of member `name` (Integer indexes the
  #   member list). Unknown names fall through to `send(name)`.
  #   @param name [Symbol, String, Integer]
  #   @return [Object]
  def [] (name)
    if name.kind_of?(Integer)
      name = members[name]
    end
    pair = self.class::DISPATCH_TABLE[name.to_s]
    if pair
      pair[0].call(@data)
    else
      send(name)
    end
  end

  # @overload []=(name, val)
  #   Sets member `name` to `val`. Unknown names fall through to
  #   `send("#{name}=", val)`.
  #   @param name [Symbol, String, Integer]
  #   @param val [Object]
  #   @return [Object] `val`.
  def []= (name, val)
    if name.kind_of?(Integer)
      name = members[name]
    end
    pair = self.class::DISPATCH_TABLE[name.to_s]
    if pair
      pair[1].call(@data, val)
    else
      send(name.to_s + "=", val)
    end
  end

  # @overload each { |value| ... }
  #   Yields each member value in declaration order.
  #   @yieldparam value [Object]
  #   @return [self]
  def each
    members.each do |name|
      yield(self[name])
    end
  end

  # @overload each_pair { |name, value| ... }
  #   Yields each member as a `(name, value)` pair in declaration
  #   order.
  #   @yieldparam name [Symbol]
  #   @yieldparam value [Object]
  #   @return [self]
  def each_pair
    members.each do |name|
      yield(name.intern, self[name])
    end
  end

  # @overload length
  #   Returns the number of members.
  #   @return [Integer]
  def length
    return self.class::MEMBERS.length
  end

  alias size length

  # @overload members
  #   Returns the member name list in declaration order.
  #   @return [Array<String>]
  def members
    return self.class::MEMBERS
  end

  # @overload values
  #   Returns the member values in declaration order.
  #   @return [Array<Object>]
  def values
    return members.map{|name| self[name] }
  end

  alias to_a values

  # @overload values_at(*names)
  #   Returns the values of the named members in the given order.
  #   @param names [Array<Symbol, String, Integer>]
  #   @return [Array<Object>]
  def values_at (*names)
    return names.map{|name| self[name] }
  end

  # @return [String] the class name followed by every member and its value.
  def inspect
    table = {}
    members.each do |key|
      table[key] = self[key]
    end
    return ["<", self.class.inspect, " ", table.inspect[1..-2], ">"].join
  end

  # Value comparison against another record of the same class.  Unlike
  # `eql?`, which compares the raw bytes, this compares the decoded members.
  # @return [Boolean]
  def == (other)
    case other
    when self.class
      return @data == other.__data__
    else
      return false
    end
  end

  # Byte-level identity.  Two CAStruct instances are eql? iff they are
  # of exactly the same class and their binary representations match.
  # Lets struct records work as Hash keys / Set members.
  def eql? (other)
    other.is_a?(self.class) && encode == other.encode
  end

  # @return [Integer] a hash consistent with #eql? (byte-level identity), so
  #   records work as Hash keys and Set members.
  def hash
    encode.hash
  end

  # @overload decode(data)
  #   Loads `data`'s binary representation into `self`. A String
  #   is loaded directly; a CArray is copied through
  #   `dump_binary` (no aliasing).
  #   @param data [String, CArray]
  #   @return [self]
  #   @raise [CAStruct::DecodeError] on an unsupported input.
  def decode (data)
    case data
    when String
      @data.load_binary(data)
    when CArray
      @data.load_binary(data.dump_binary)
    else
      raise CAStruct::DecodeError,
            format("unknown data to decode: %s", data.class)
    end
    return self
  end

  # @overload encode
  #   Returns the binary representation of `self` matching this
  #   struct's layout.
  #   @return [String]
  def encode                          ### required element as data class
    return @data.dump_binary
  end

  # @overload swap_bytes!
  #   Byte-swaps `self` in place (endian flip).
  #   @return [self]
  def swap_bytes!
    @data[] = @data.swap_bytes
    return self
  end

  # @overload swap_bytes
  #   Returns a fresh byte-swapped copy of `self`.
  #   @return [CAStruct]
  def swap_bytes
    return self.class.decode(@data.swap_bytes.dump_binary)
  end

  # @overload to_ptr
  #   Returns a `Fiddle::Pointer` to the backing storage.
  #   @return [Fiddle::Pointer]
  def to_ptr
    return @data.to_ptr
  end

end

# Struct whose members all start at offset 0, so they are alternative
# readings of the same bytes.  Otherwise behaves as a {CAStruct}.
class CAUnion < CAStruct
  class << self
    # @return [String] the union's name, or `"AnonUnion"` when it was
    #   defined anonymously.
    def inspect
      return name.nil? ? "AnonUnion" : name
    end
  end
end

class CArray

  # @overload struct(opt = {}, &block)
  #   Returns a new {CAStruct} subclass defined by the block via
  #   {CAStruct::Builder}. Options control alignment, packing, and
  #   endianness.
  #   @param opt [Hash]
  #   @yield DSL calls in {CAStruct::Builder}.
  #   @return [Class] anonymous {CAStruct} subclass.
  def self.struct (opt={}, &block)
    return CAStruct::Builder.new(:struct, opt).define(&block)
  end

  # @overload union(opt = {}, &block)
  #   Returns a new {CAUnion} subclass defined by the block. Same
  #   options and DSL as {.struct} but every member occupies the
  #   same offset.
  #   @param opt [Hash]
  #   @yield DSL calls in {CAStruct::Builder}.
  #   @return [Class] anonymous {CAUnion} subclass.
  def self.union (opt={}, &block)
    return CAStruct::Builder.new(:union, opt).define(&block)
  end

end


class CAStruct

  # Renders the struct's layout as the definition source that would rebuild
  # it — member names, types, offsets and any nested struct.
  # @return [String]
  def self.spec
    output = ""
    table  = self::MEMBER_TABLE
    stlist = []
    if self.name.nil?
      if self <= CAUnion
        prefix = "union"
      else
        prefix = "struct"
      end
      output << sprintf("%s_%i = ", 
                        prefix, [object_id].pack("V").unpack("V").first)
    else
      output << sprintf("%s = ", self.name)
    end
    if self < CAUnion
      output << sprintf("CArray.union(:size=>%i) {\n", self::DATA_SIZE)
    else
      output << sprintf("CArray.struct(:size=>%i) {\n", self::DATA_SIZE)
    end
    members.each do |member|
      offset, type, option = *table[member]
      case type
      when Class
        if type < CAStruct
          stlist << type
          if type.name.nil?
            if type <= CAUnion
              prefix = "union"
            else
              prefix = "struct"
            end
            output << sprintf("  member %s_%i, :%s, :offset=>%i\n", 
                              prefix,
                              [type.object_id].pack("V").unpack("V").first,
                              member, offset)
          else
            output << sprintf("  member %s, :%s, :offset=>%i\n", 
                              type.name, member, offset)
          end
        else
          raise "unknown type"
        end
      when CArray
        output << sprintf("  member %s, :%s, :offset=>%i\n", 
                          type.spec, member, offset)
      when :fixlen
        output << sprintf("  member :fixlen, :%s, :bytes=>%i, :offset=>%i\n", 
                          member, option[:bytes], offset)
      else
        output << sprintf("  member :%s, :%s, :offset=>%i\n", 
                          type, member, offset)
      end
    end
    output << sprintf("}\n")
    if stlist.empty?
      return output
    else
      stlist.uniq!
      preface = ""
      stlist.each do |st|
        preface << st.spec
      end
      return preface + output
    end
  end

  # @return [String] the layout of this record's class; see {CAStruct.spec}.
  def spec
    return self.class.spec
  end

end

# Hand the C extension a reference to CAStruct so it can override
# `[]` / `[]=` with the fast primitive-aware C path defined in
# ext/carray_struct.c.
#
# CAREFUL: this must run AFTER CAStruct's Ruby [] / []= are defined
# above (so the C versions can replace them) and AFTER FAST_PRIMITIVES /
# DISPATCH_TABLE keys are agreed upon (so the per-class struct definition
# in Builder sets them up before any instance is created).  Subclasses
# created by Builder later don't need re-installation -- they inherit the
# C methods from CAStruct.
if CArray.respond_to?(:__install_castruct_methods__)
  CArray.__install_castruct_methods__(CAStruct)
end



# ----------------------------------------------------------------------------
#
#  carray/struct.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------
#
# The data class for fixed length carray are required to satisfy only
# four conditions.
#
#   * constant data_class::DATA_SIZE    -> integer
#   * constant data_class::MEMBERS      -> array of string
#   * constant data_class::MEMBER_TABLE -> hash
#   * method   data_class.decode(data)  -> new data_class object
#   * method   data_class#encode()      -> string 
#
# The implementation of other properties (cf. initialization, instance,
# methods ...) are left free.
#
# CA::Struct and CA::Union are examples of such data class.
#
# option = {
#   :pack => 1,   # nil for alignment, int for pack(n)
#   :size => 1024 # user defined size (with padding)
# }
# 
# CA.struct(option) { |s|
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
#   struct :st3, :st4, :type => CA.struct { uint8 :a, :b, :c }
# 
#   # union type
#   union(:un1, :un2) { uint8 :a; int16 :b; float32 :c }
#   union :un3, :un4, :type => CA.union { uint8 :a, :b, :c }
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
#

class CArray

  def st
    unless has_data_class?
      raise "should have data_class"
    end
    unless @struct
      struct_class = Struct.new(nil, *data_class::MEMBERS)
      members = data_class::MEMBERS.map{|name| self[name]}
      @struct = struct_class.new(*members)
    end
    return @struct
  end

end

class CA::Struct

  include Enumerable

  class << self
    
    def inspect
      return name.nil? ? "AnonStruct" : name
    end
    
    def [] (*argv)
      obj = new()
      members.each do |name|
        obj[name] = argv.shift
      end
      return obj
    end
    
    def members
      return self::MEMBERS.clone
    end
    
    def decode (data)                        ### required element as data class
      return new.decode(data)
    end
    
    def size
      return self::DATA_SIZE
    end

  end

  def initialize (*argv)
    @data = CScalar.new(self.class)
    mems = members
    if argv.size == 1 and argv.first.is_a?(Hash)
      argv.first.each do |k,v|
        self[k] = v
      end
    elsif argv.size <= mems.size
      argv.each_with_index do |v, i|
        self[mems[i]] = v
      end
    else
      raise ArgumentError, 
            format("too many arguments for %s.new (<%i> for <%i>)", 
                   self.class.inspect, argv.size, members.size)
    end
  end

  protected

  def __data__
    @data
  end

  public

  def [] (name)
    if name.kind_of?(Integer)
      name = members[name]
    end
    offset, type, opts = *self.class::MEMBER_TABLE[name.to_s]
    case type
    when nil
      return send(name)
    when Class
      return type.decode(@data.field(offset, type))
    when CArray
      return @data.field(offset,type)[0,false]
    else
      return @data.field(offset,type,opts)[0]
    end
  end

  def []= (name, val)
    if name.kind_of?(Integer)
      name = members[name]
    end
    offset, type, opts = *self.class::MEMBER_TABLE[name.to_s]
    case type
    when nil
      send(name.to_s + "=", val)    
    when Class
      @data.field(offset, type)[0] = val
    when CArray
      @data.field(offset, type)[0,false] = val
    else
      @data.field(offset,type,opts)[0] = val
    end
  end

  def each
    members.each do |name|
      yield(self[name])
    end
  end

  def each_pair
    members.each do |name|
      yield(name.intern, self[name])
    end
  end

  def length
    return self.class::MEMBERS.length
  end
  
  alias size length

  def members
    return self.class::MEMBERS.clone
  end

  def values
    return members.map{|name| self[name] }
  end

  alias to_a values

  def values_at (*names)
    return names.map{|name| self[name] }
  end

  def inspect
    table = {}
    members.each do |key|
      table[key] = self[key]
    end
    return ["<", self.class.inspect, " ", table.inspect[1..-2], ">"].join
  end

  def == (other)
    case other
    when self.class
      return @data == other.__data__
    else
      return false
    end
  end

  def decode (data)
    case data
    when String
      @data.load_binary(data)
    when CArray
      @data = data
    else
      raise "unkown data to decode"
    end
    return self
  end

  def encode                          ### required element as data class
    return @data.dump_binary
  end

  alias to_s encode

  def swap_bytes!
    @data.swap_bytes!
    return self
  end

  def swap_bytes
    return self.class.decode(@data.swap_bytes.dump_binary)
  end

  def to_ptr
    return @data.to_ptr
  end

end

class CA::Union < CA::Struct
  class << self
    def inspect
      return name.nil? ? "AnonUnion" : name
    end
  end
end

module CA

  def self.struct (opt={}, &block)
    return Struct::Builder.new(:struct, opt).define(&block)
  end

  def self.union (opt={}, &block)
    return Struct::Builder.new(:union, opt).define(&block)
  end

end

# ---------------------------------------------------------------------
#
# Struct Builder Class
#
# ---------------------------------------------------------------------

class CA::Struct::Builder  # :nodoc:

  class Member # :nodoc:

    def initialize (name, type, opt={})
      @name, @type, @opt = name, type, opt
      if @type.kind_of?(CArray)
        @type = @type.to_ca
        @byte_length = @type.bytes * @type.elements
        @bytes  = 0
      else
        data_type, @bytes = CArray.guess_type_and_bytes(@type, @opt[:bytes])
        if data_type == CA_OBJECT
          raise RuntimeError, "CA_OBJECT type can't be a member of struct or union"
        end 
        @byte_length = @bytes
      end
      @offset = @opt[:offset]
    end

    attr_reader :name, :type, :offset, :bytes, :byte_length

  end

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

  CARRAY_METHODS = CArray.instance_methods.map{|m| m.intern }

  def initialize (type, opt = {})
    if not opt[:pack].nil? and not opt[:pack].is_a?(Integer)
      raise "invalid alignment given '#{align}'"
    end
    @type      = type       ### :struct or :union
    @align     = opt[:pack] ### nil for alignment, int for pack(n)
    @members   = []         ### array of CArray::Struct::Builder::Member
    @offset    = 0          ### offset of each member and size of struct
    @align_max = 1          ### maximum of alignment among members
    @size      = opt[:size] ### user defined struct size
  end

  def define (&block)
    # ---
    case block.arity
    when 1
      block.call(self)      ### struct/union definition block
    when -1, 0
      instance_exec(&block) ### struct/union definition block
    else
      raise "invalid # of block parameters"
    end
    # ---
    case @type
    when :struct
      klass = Class.new(CA::Struct)
    when :union
      klass = Class.new(CA::Union)
    end
    # ---
    if @align.nil?
      @offset = alignment(@offset, :align_max)
    end
    if @size
      if @size < @offset
        raise RuntimeError, "struct size exceeds the fixlen size"
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
      if bytes
        table[name] = [offset, type, {:bytes=>bytes}]
      else
        table[name] = [offset, type]
      end
      names.push(name)
    end
    klass.const_set(:MEMBER_TABLE, table)   ### required element as data class
    klass.const_set(:MEMBERS, names)
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
    case data_type
    when Integer
      align = ALIGN_TABLE[data_type]
    when CArray, Class
      align = CA_ALIGN_VOIDP
    when :align_max
      align = @align_max
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
      raise "invalid offset for packing"
    end
    return addr
  end

  public

  def member (data_type, id = nil, opt = {})
    opt = opt.clone
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

  # method for nested struct
  def struct (*args, &block)
    opt = args.last.is_a?(Hash) ? args.pop : {}   
    if block
      opt = {:pack => @align}.update(opt)
      st = self.class.new(:struct, opt).define(&block)
    elsif opt[:type] and opt[:type] <= CA::Struct
      st = opt[:type]
    else
      raise "type is not given for struct member of struct"
    end
    args.each do |arg|
      member(st, arg)
    end
    return st
  end

  # method for nested union
  def union (*args, &block)
    opt = args.last.is_a?(Hash) ? args.pop : {}   
    if block
      opt = {:pack => @align}.update(opt)
      st = self.class.new(:union, opt).define(&block)
    elsif opt[:type] and opt[:type] <= CA::Struct
      st = opt[:type]
    else
      raise "type is not given for union member of struct"
    end
    args.each do |arg|
      member(st, arg)
    end
    return st
  end

  def array (*args)
    opt = args.last.is_a?(Hash) ? args.pop : {}   
    if not opt[:type] or not opt[:type].kind_of?(CArray)
      raise "type is not given for array member of struct"
    end
    args.each do |arg|
      member(opt[:type], arg)
    end
  end

  [
   "fixlen",
   "boolean",
   "int8",
   "uint8",
   "int16",
   "uint16",
   "int32",
   "uint32",
   "int64",
   "uint64",
   "float32",
   "float64",
   "float128",
   "cmplx64",
   "cmplx128",
   "cmplx256",
  ].each do |typename|
    class_eval %{
      def #{typename} (*args)
        opt = args.last.is_a?(Hash) ? args.pop : {}
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



class CA::Struct

  def self.spec
    output = ""
    table  = self::MEMBER_TABLE
    stlist = []
    if self.name.nil?
      if self <= CA::Union
        prefix = "union"
      else
        prefix = "struct"
      end
      output << sprintf("%s_%i = ", 
                        prefix, [object_id].pack("V").unpack("V").first)
    else
      output << sprintf("%s = ", self.name)
    end
    if self < CA::Union
      output << sprintf("CA.union(:size=>%i) {\n", self::DATA_SIZE)
    else
      output << sprintf("CA.struct(:size=>%i) {\n", self::DATA_SIZE)
    end
    members.each do |member|
      offset, type, option = *table[member]
      case type
      when Class
        if type < CA::Struct
          stlist << type
          if type.name.nil?
            if type <= CA::Union
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

  def spec
    return self.class.spec
  end
  
end



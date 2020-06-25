# ----------------------------------------------------------------------------
#
#  carray/base/serialize.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------
#
#
# CArray.save(ca, filename, {:endian=>CArray.endian})
# CArray.save(ca, io, {:endian=>CArray.endian})
#
# CArray.load(filename)
# CArray.load(io)
#
# CArray.dump(filename, {:endian=>CArray.endian})
#
# CArray#marshal_dump
# CArray#marshal_load(data)
#

#
# CArray's Binary Format
#
# offset 0 bytes
#   magic_string     : char*8 : "_CARRAY_"
#   data_type_name   : char*8 : e.g. "int8", "cmplx256" ...
#   endian           : char*4 : "_LE_":LITTLE_ENIDAN or "_BE_":BIG_ENDIAN
# offset 20 bytes
#   data_type        : int32  : data type specifier
#   bytes            : int32  : byte size of each data
#   rank             : int32  : rank of array
#   elements         : int32  : number of all elements
#   has_mask         : int32  : 0 (not masked) or 1 (masked)
# offset 40 bytes
#   dim[CA_RANK_MAX] : int32  : size for 0-th dimension
#   has_attribute    : int32  
#
# offset 256 bytes
#   data           : bytes*elements : value data
#   mask           : int8*elements  : mask data if has_mask == 1

require "stringio"

class CArray::Serializer   # :nodoc: 

  Header = CA.struct(:pack=>1, :size=>256) {
    char_p    :magic_string,   :bytes=>8
    char_p    :data_type_name, :bytes=>8
    char_p    :endian,         :bytes=>4
    int32     :data_type
    int64     :bytes
    int32     :rank
    int64     :elements
    int32     :has_mask
    array     :dim,            :type => CArray.int64(CA_RANK_MAX)
    int32     :has_attr
  }

  Header_Legacy = CA.struct(:pack=>1, :size=>256) {
    char_p    :magic_string,   :bytes=>8
    char_p    :data_type_name, :bytes=>8
    char_p    :endian,         :bytes=>4
    int32     :data_type
    int32     :bytes
    int32     :rank
    int32     :elements
    int32     :has_mask
    array     :dim,            :type => CArray.int32(CA_RANK_MAX)
    int32     :has_attr
  }

  def initialize (io)
    case io
    when String
      @io = StringIO.new(io)
    else
      @io = io
    end
  end

  def save (ca, opt = {})
    endian = opt[:endian] || CArray.endian
    # ---
    header = Header.new()
    header[:magic_string]   = "_CARRAY_"
    header[:data_type_name] = ca.data_type_name.ljust(8)
    header[:endian]         = ( endian == CA_LITTLE_ENDIAN ) ? "_LE_" : "_BE_"
    header[:data_type]      = ca.data_type
    header[:bytes]          = ca.bytes
    header[:rank]           = ca.rank
    header[:elements]       = ca.elements
    header[:has_mask]       = ca.has_mask? ? 1 : 0
    header[:dim][[0,ca.rank]] = ca.dim
    attr = nil
    if ca.attribute
      attr = ca.attribute.clone
    end
    if opt[:attribute]
      (attr ||= {}).update(opt[:attribute])
    end
    header[:has_attr]       = attr.empty? ? 0 : 1
    unless CArray.endian == endian
      header.swap_bytes!
    end
    @io.write(header.encode)
    # ---
    if ca.data_type == CA_OBJECT
      Marshal.dump(ca.value.to_a, @io)
    else
      unless CArray.endian == endian
        ca = ca.swap_bytes
      end
      ca.dump_binary(@io)
    end
    # ---
    if ca.has_mask?
      ca.mask.dump_binary(@io)
    end
    if attr
      Marshal.dump(attr, @io)
    end
    return ca
  end
  
  def load (opt = {}, legacy: false)
    if legacy
      header = Header_Legacy.decode(@io.read(256))
    else
      header = Header.decode(@io.read(256))
    end
    if header[:magic_string] != "_CARRAY_"
      raise "not a CArray binary data"      
    end
    case header[:endian]
    when "_LE_"
      endian = CA_LITTLE_ENDIAN
    when "_BE_"
      endian = CA_BIG_ENDIAN
    end
    unless CArray.endian == endian
      header.swap_bytes!
    end
    data_type = header[:data_type]
    bytes     = header[:bytes]
    rank      = header[:rank]
    elements  = header[:elements]
    has_mask  = header[:has_mask] != 0 ? true : false
    dim       = header[:dim][[0, rank]].to_a
    has_attr  = header[:has_attr]
    if data_type == 255
      data_type = header[:data_type_name].strip.to_sym
    end
    data_type, bytes = CArray.guess_type_and_bytes(data_type, bytes)
    if opt[:data_type] and data_type == CA_FIXLEN
      data_type = opt[:data_type]
    end
    ca = CArray.new(data_type, dim, :bytes=>bytes)
    if data_type == CA_OBJECT
      ca.value[] = Marshal.load(@io)
    else
      ca.load_binary(@io)
      unless CArray.endian == endian
        ca.swap_bytes!
      end
    end
    if has_mask
      ca.mask = 0
      ca.mask.load_binary(@io)
    end
    if has_attr == 1
      ca.attribute = Marshal.load(@io)
    end
    return ca
  end
  
end

class CArray

  def self.save(ca, output, opt={})
    case output
    when String
      open(output, "wb:ASCII-8BIT") { |io|
        return Serializer.new(io).save(ca, opt)
      }
    else
      return Serializer.new(output).save(ca, opt) 
    end
  end

  def self.load (input, opt={})
    case input
    when String
      if input.length >= 256 and input =~ /\A_CARRAY_.{8}_(LE|BE)_/
        io = StringIO.new(input)
        return Serializer.new(io).load(opt)
      else
        open(input, "rb:ASCII-8BIT") { |io|
          return Serializer.new(io).load(opt)
        }
      end
    else
      return Serializer.new(input).load(opt)   
    end
  end

  def self.dump (ca, opt={})
    io = StringIO.new("")
    Serializer.new(io).save(ca, opt) 
    return io.string
  end

  # for Marshal

  def marshal_dump ()
    if self.class != CArray and self.class != CScalar
      return CArray.dump(self.to_ca)
#      raise TypeError, "can't dump a virtual or wrapped array."
    end
    return CArray.dump(self)
  end

  def marshal_load (data)
    io = StringIO.new(data)
    ca = CArray.load(io)
    initialize_copy(ca)
  end

  ### obsolete methods

  def save_binary (filename, opt={})    # :nodoc: 
    warn "CArray#save_binary will be obsolete, use CArray.save"
    open(filename, "w") { |io|
      return Serializer.new(io).save(self, opt)
    }
  end

  def self.load_binary (filename, opt={})     # :nodoc: 
    warn "CArray.load_binary will be obsolete, use CArray.load"
    open(filename) { |io|
      return Serializer.new(io).load(opt)
    }
  end

  def save_binary_io (io, opt={})        # :nodoc:
    warn "CArray#save_binary_io will be obsolete, use CArray.save"
    return Serializer.new(io).save(self, opt) 
  end

  def self.load_binary_io (io, opt={})   # :nodoc:
    warn "CArray#load_binary_io will be obsolete, use CArray.load"
    return Serializer.new(io).load(opt)   
  end 

  def to_binary (io="", opt={})          # :nodoc:
    warn "CArray#to_binary will be obsolete, use CArray.dump"
    Serializer.new(io).save(self, opt) 
    return io
  end

  def self.from_binary (io, opt={})      # :nodoc:
    warn "CArray.from_binary will be obsolete, use CArray.load"
    return Serializer.new(io).load(opt)   
  end 

  # depleted methods

  def self.load_from_file (filename, data_type, dim, opt={}) # :nodoc:
    raise "Sorry, CArray.load_from_file is depleted"
  end

end


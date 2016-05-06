# ----------------------------------------------------------------------------
#
#  carray/io/fortran_namelist.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

require "carray"
require "fortio/fortran_namelist.tab"

class FortranNamelistReader
  
  def initialize (text)
    @namelist = FortranNamelistParser.new.parse(text)
  end
  
  def read (name, out={})
    name = name.downcase
    unless nml = @namelist[name]
      raise "no definition of namelist '#{name}'"
    end
    nml.each do |paramdef|
      paramdef.set(out)
    end
    return out
  end

  def read_all 
    all = {}
    @namelist.each do |name, nml|
      all[name] = {}
      read(name, all[name])
    end
    return all
  end

  attr_reader :namelist
  
end

def fortran_namelist (name, out)
  list = out.map{ |ident, value|
    case value
    when CArray
      ident = "#{ident}(" + value.dim.map{|d| "1:#{d}" }.join(",") + ")"
      value = value.flatten.to_a.join(",")
    when Array
      value = value.flatten.join(",")
    when String
      if value !~ /'/
        value = "'" + value + "'"
      else 
        value = '"' + value.gsub(/"/, '""') + '"'
      end
    when Float
      value = value.to_s.sub(/e/, "d")
    end
    " #{ident} = #{value}" 
  }
  return ["&#{name}", list.join(",\n") + "  /"].join("\n")
end

def fortran_namelist_read (io, name=nil, out={})
  case io
  when String
    text = io
  else
    text = io.read
  end
  if name
    return FortranNamelistReader.new(text).read(name, out)
  else
    return FortranNamelistReader.new(text).read_all()
  end
end

def fortran_namelist_write (io, name, out)
  io << fortran_namelist(name, out)
  return io
end

class FortranNamelistParser
  
  ParamDef = Struct.new(:ident, :array_spec, :rval)
  class ParamDef
    def set (hash)
      case hash[ident]
      when CArray
        hash[ident].attach { |ca|
          if array_spec
            crv = rval.to_ca
            if crv.search(nil)
              mask = crv.ne(nil)
              ca[*array_spec][0...crv.size][mask] = crv[mask]
            elsif ca[*array_spec].is_a?(CArray)
              ca[*array_spec][0...crv.size] = crv              
            else 
              ca[*array_spec] = rval.first
            end
          else
            if rval.is_a?(Array) and rval.size == 1
              ca[0] = rval.first
            else
              ca[0...rval.size] = rval
            end
          end
        }
      when Array
        if array_spec
          if array_spec.first.is_a?(Integer) and rval.size == 1
            hash[ident][*array_spec] = rval.first
          else
            hash[ident][*array_spec] = rval.first
          end
        else
          if rval.is_a?(Array) and rval.size == 1
            hash[ident][0] = rval.first
          else
            hash[ident].clear
            hash[ident].push(*rval)
          end
        end        
      else
        if array_spec
          hash[ident] = []
          set(hash)
        else
          if rval.is_a?(Array) and rval.size == 1
            hash[ident] = rval.first
          else
            hash[ident] = rval
          end
        end
      end
    end
    def inspect
      if array_spec
        return "#{ident}(#{array_spec.inspect}) = #{rval.inspect}"
      else
        return "#{ident} = #{rval}"
      end
    end
  end

end


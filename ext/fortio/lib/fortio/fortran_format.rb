# ----------------------------------------------------------------------------
#
#  carray/io/fortran_format.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------
#
# Supported format descriptors
# ----------------------------
#   nFw.d        : floating point
#   nEw.d        : floating point
#   nDw.d        : floating point
#   nGw.d        : floating point
#   nESw.d       : 
#   nEd          : exponential
#   nIw(.d)      : integer
#   nLw          : logical
#   nAw          : string
#   nX           : write n white space or skip reading by n-characters
#   Tn           : move to n-character from line head
#   TLn          : move left relative by n-characters
#   TRn          : move right relative by n-characters
#   +P, -P
#   S, SP, SS
#   BN,BZ        
#   nH...        : hollerith string (e.g. 5Hhello)
#   '...', "..." : quoted string
#   /            : line feed
#   $            : surppress line feed
#
# Short methods
# -------------
#
# ### fortran_format(fmt, *vals)
#
# ### fortran_format_write(io, fmt, *vals)
#
# ### fortran_format_read(io, fmt)
#


require "fortio_ext"
require "fortio/fortran_format.tab"
require "stringio"

class FortranFormat

  FORMAT_POOL = Hash.new { |hash, fmt| 
    hash[fmt] = FortranFormatParser.new.parse(fmt)
  }

  def self.reset
    FORMAT_POOL.clear
  end

  def initialize (fmt)
    @format = FORMAT_POOL[fmt]
  end

  def write (io, *list)
	  io ||= ""
    buf = StringIO.new()
    @format.write_as_root(buf, list)
    io << buf.string
    return io 
  end

  def read (io, list = [])
    if io.is_a?(String)
      io = StringIO.new(io)
    end
    @format.read_as_root(io, list)
    return list
  end
  
  def count_args
    return @format.count_args
  end
  
  def inspect
    return "<FortranFormat: #{@format.inspect}>"
  end
  
end

def FortranFormat.check_length (len, str)
  if str.length > len
    return "*" * len
  else
    return str
  end
end

def FortranFormat (fmt)
  return FortranFormat.new(fmt)
end

def fortran_format_write (io, fmt, *data)
  if fmt.is_a?(FortranFormat)
    return fmt.write(io, *data)
  else
    return FortranFormat.new(fmt).write(io, *data)
  end
end

def fortran_format_read (io, fmt)
  if fmt.is_a?(FortranFormat)
    return fmt.read(io)
  else
    return FortranFormat.new(fmt).read(io)
  end
end

def fortran_format (fmt, *data)
  return fortran_format_write(nil, fmt, *data)
end

class FortranFormatParser
  
  State = Struct.new(:scale, :sign, :zero, :continue, :pos0, :tab_move)
  
  Group = Struct.new(:count, :member)
  class Group 
    def write_as_root (io, list)
      state = State.new(0, false, false, false, io.pos, false)
      write(io, list, state)
      if state.continue
        if state.tab_move
	        io.string.gsub!(/\000/, ' ')
	      end
	    else
	      if state.tab_move
	        io.string.gsub!(/\000/, ' ')
          io.seek(0, IO::SEEK_END)
	      end
        io.puts
		  end
    end
    def write (io, list, state)
      count.times do |i|
        member.each do |mem|
          mem.write(io, list, state)
        end
      end
    end
    def read_as_root (io, list)
      state = State.new(0, false, false, false, io.pos, false)
      read(io, list, state)
      unless state.continue
        io.gets
      end
    end
    def read (io, list, state)
      count.times do |i|
        member.each do |mem|
          mem.read(io, list, state)
        end
      end
    end
    def count_args
      return count*member.inject(0){|s,m| s + m.count_args}
    end
    def inspect
      count_str = count == 1 ? "" : count.to_s
      return "#{count_str}(" + member.map{|x| x.inspect}.join(",")+ ')'
    end
  end

  class Continue
    def write (io, list, state)
      state.continue = true
    end
    def read (io, list, state)
      state.continue = true
    end
    def count_args
      return 0
    end
    def inspect
      return "$"
    end
  end
  
  Flush = Struct.new(:count)
  class Flush
    def write (io, list, state)
      io << "\n" * count
    end
    def read (io, list, state)
      count.times do 
        io.gets
      end
    end
    def count_args
      return count
    end  
    def inspect
      count_str = count == 1 ? "" : count.to_s
      return "#{count_str}/"
    end
  end

  NodeS = Struct.new(:text)
  class NodeS
    def write (io, list, state)
      io << text
    end
    def read (io, list, state)
      raise RuntimeError, "constant string for reading"
    end
    def count_args
      return 0
    end  
    def inspect
      if text !~ /'/
        return "'" + text + "'"
      else 
        return '"' + text.gsub(/"/, '""') + '"'
      end
    end
  end

  NodeT= Struct.new(:n)
  class NodeT
    def write (io, list, state)
      io.pos = state.pos0 + n
      state.tab_move = true
    end
    def read (io, list, state)
      io.pos = state.pos0 + n
    end
    def count_args
      return 0
    end  
    def inspect
      return "TL#{n}"
    end
  end

  NodeTL = Struct.new(:n)
  class NodeTL
    def write (io, list, state)
      io.pos -= n
      state.tab_move = true
    end
    def read (io, list, state)
      io.pos -= n
    end
    def count_args
      return 0
    end  
    def inspect
      return "TL#{n}"
    end
  end

  NodeTR = Struct.new(:n)
  class NodeTR
    def write (io, list, state)
      io.pos += n
      state.tab_move = true
    end
    def read (io, list, state)
      io.pos += n
    end
    def count_args
      return 0
    end  
    def inspect
      return "TR#{n}"
    end
  end

  NodeX = Struct.new(:count)
  class NodeX
    def write (io, list, state)
      io << " " * count
    end
    def read (io, list, state)
      io.read(count)
    end
    def count_args
      return 0
    end  
    def inspect
      count_str = count == 1 ? "" : count.to_s
      return "#{count_str}X"
    end
  end

  NodeP = Struct.new(:scale)
  class NodeP
    def write (io, list, state)
      state.scale = scale
    end
    def read (io, list, state)
      state.scale = scale      
    end
    def count_args
      return 0
    end  
    def inspect
      return "#{scale}P"
    end
  end

  NodeSp = Struct.new(:sign)
  class NodeSp
    def write (io, list, state)
      state.sign = sign
    end
    def read (io, list, state)
    end
    def count_args
      return 0
    end  
    def inspect
      if sign
        return "SP"
      else
        return "SS"
      end
    end
  end

  NodeB = Struct.new(:zero)
  class NodeB
    def write (io, list, state)
    end
    def read (io, list, state)
      state.zero = zero
#      if zero
#        warn "FortranFormat: BZ is not supported descriptor"
#      end
    end
    def count_args
      return 0
    end  
    def inspect
      if zero
        return "BZ"
      else
        return "BN"
      end
    end
  end

  NodeH = Struct.new(:count, :string)
  class NodeH
    def write (io, list, state)
      io << string
    end
    def read (io, list, state)
      raise "format h is not implemented for reading"
    end
    def count_args
      return count
    end  
    def inspect
      count_str = count == 1 ? "" : count.to_s
      return "#{count_str}H#{string}"
    end
  end

  NodeA = Struct.new(:count, :length)
  class NodeA
    def write (io, list, state)
      len = length
      if len
        count.times do 
          str = list.shift
          if str.length > len
            io << str[0,len]
          else
            io << str.rjust(len)
          end
        end
      else
        io << str
      end
    end
    def read (io, list, state)
      str = nil
      if length
        list << (str = io.read(length))
      else
        list << (str = io.read)
      end
    rescue
      raise "reading error in fortran format : #{str.dump} for #{self.inspect}"
    end
    def count_args
      return count
    end  
    def inspect
      count_str = count == 1 ? "" : count.to_s
      return "#{count_str}A#{length}"
    end
  end

  NodeL = Struct.new(:count, :length)
  class NodeL
    def write (io, list, state)
      count.times do
        if list.shift
          io << " "*(length-1) + "T"
	      else
          io << " "*(length-1) + "F"
		    end
		  end
    end
    def read (io, list, state)
      count.times do
        case io.read(length)
	      when /\A *?\.?t/i
		      list.push(true)
		    else
			    list.push(false)
		    end
		  end      
    end
    def count_args
      return count
    end  
    def inspect
      count_str = count == 1 ? "" : count.to_s
      return "#{count_str}L#{length}"
    end
  end

  NodeI = Struct.new(:count, :length, :prec)
  class NodeI
    def write (io, list, state)
      if prec
        if state.sign
          fmt = "%#{length-prec}s%+0#{prec-1}i"
        else
          fmt = "%#{length-prec}s%0#{prec}i"        
        end
      else
        if state.sign
          fmt = "%s%+#{length-1}i"
        else
          fmt = "%s%#{length}i"        
        end
      end 
      count.times do
        str = format(fmt, "", list.shift)
        io << FortranFormat.check_length(length, str)
      end
    end
    def read (io, list, state)
      str = nil
      count.times do
        str = io.read(length)
        if state.zero 
          list << str.gsub(/ /,'0').to_i
        else
          list << Integer(str)
        end
      end
    rescue
      raise "reading error in fortran format : #{str.dump} for #{self.inspect}"
    end
    def count_args
      return count
    end  
    def inspect
      count_str = count == 1 ? "" : count.to_s
      if prec
        return "#{count_str}I#{length}.#{prec}"
      else
        return "#{count_str}I#{length}"        
      end
    end
  end
  
  NodeF = Struct.new(:count, :length, :prec)
  class NodeF
    def write (io, list, state)
      count.times do
        str = FortranFormat.write_F(state.sign, state.scale, length, prec, list.shift)
        io << FortranFormat.check_length(length, str)
      end
    end
    def read (io, list, state)
      str = nil
      count.times do
        str = io.read(length)
        if state.zero 
          str = str.gsub(/ /,'0')
        end
        list << FortranFormat.read_F(str, state.scale, length, prec)
      end
    rescue
      raise "reading error in fortran format : #{str.dump} for #{self.inspect}"
    end
    def count_args
      return count
    end  
    def inspect
      count_str = count == 1 ? "" : count.to_s
      return "#{count_str}F#{length}.#{prec}"
    end
  end

  NodeE = Struct.new(:count, :length, :prec, :exp)
  class NodeE
    def write (io, list, state) 
      count.times do
        str = FortranFormat.write_E(state.sign, state.scale, length, prec, exp, list.shift)
        io << FortranFormat.check_length(length, str)
      end
    end
    def read (io, list, state)
      str = nil
      count.times do
        str = io.read(length)
        if state.zero 
          str = str.gsub(/ /,'0')
        end
        list << str.to_f
      end
    rescue
      raise "reading error in fortran format : #{str.dump} for #{self.inspect}"
    end
    def count_args
      return count
    end  
    def inspect
      count_str = count == 1 ? "" : count.to_s
      exp_str   = (exp.nil? or exp == 2) ? "" :  "E#{exp}"
      return "#{count_str}E#{length}.#{prec}#{exp_str}"
    end
  end

  NodeES = Struct.new(:count, :length, :prec, :exp)
  class NodeES
    def write (io, list, state) 
      count.times do
        str = FortranFormat.write_E(state.sign, 1, length, prec, exp, list.shift)
        io << FortranFormat.check_length(length, str)
      end
    end
    def read (io, list, state)
      str = nil
      count.times do
        str = io.read(length)
        if state.zero 
          str = str.gsub(/ /,'0')
        end
        list << str.to_f
      end
    rescue
      raise "reading error in fortran format : #{str.dump} for #{self.inspect}"
    end
    def count_args
      return count
    end  
    def inspect
      count_str = count == 1 ? "" : count.to_s
      exp_str   = (exp.nil? or exp == 2) ? "" :  "E#{exp}"
      return "#{count_str}ES#{length}.#{prec}#{exp_str}"
    end
  end

  NodeG = Struct.new(:count, :length, :prec, :exp)
  class NodeG
    def write (io, list, state)
      count.times do
        str = FortranFormat.write_G(state.sign, state.scale, length, prec, exp, list.shift)
        io << FortranFormat.check_length(length, str)
      end
    end
    def read (io, list, state)
      str = nil
      count.times do
        str = io.read(length)
        if state.zero 
          str = str.gsub(/ /,'0')
        end
        list << str.to_f
      end
    rescue
      raise "reading error in fortran format : #{str.dump} for #{self.inspect}"
    end
    def count_args
      return count
    end  
    def inspect
      count_str = count == 1 ? "" : count.to_s
      exp_str   = (exp.nil? or exp == 2) ? "" :  "E#{exp}"
      return "#{count_str}G#{length}.#{prec}#{exp_str}"
    end
  end
    
end


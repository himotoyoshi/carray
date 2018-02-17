# ----------------------------------------------------------------------------
#
#  fortio/fortran_sequential.rb
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
# Format
#
#   real*4    : native endian => "f", "F"
#               little endian => "e"
#               big endian    => "g"
#
#   real*8    : native endian => "d", "D"
#               little endian => "E"
#               big endian    => "G"
#
#   integer*2 : native endian => "s"
#               little endian => "v"
#               big endian    => "n"
#
#   integer*4 : native endian => "l"
#               little endian => "V"
#               big endian    => "N"
#
#   character : "a"
#

require "stringio"
require "carray"

class FortranSequential

  if "ab".unpack("v").pack("s") == "ab"
    ENDIAN = "little"
  else
    ENDIAN = "big"
  end

  FMT_VAX = {
    "f" => "e", "F" => "e", "e" => "e", "g" => "g",
    "d" => "E", "D" => "E", "E" => "E", "G" => "G",
    "s" => "v",             "v" => "v", "n" => "n",
    "l" => "V",             "V" => "V", "N" => "N",
    "a" => "a"
  }

  FMT_NET = {
    "f" => "g", "F" => "g", "e" => "e", "g" => "g",
    "d" => "G", "D" => "G", "E" => "E", "G" => "G",
    "s" => "n",             "v" => "v", "n" => "n",
    "l" => "N",             "V" => "V", "N" => "N",
    "a" => "a"
  }
  
  def self.open (file, mode="r", opt={:endian=>nil})
    io = Kernel::open(file, mode)
    if mode =~ /r/
      fs = FortranSequentialReader.new(io, opt)
    else
      fs = FortranSequentialWriter.new(io, opt)
    end
    if block_given?
      begin
        yield(fs)
      ensure
        fs.close
      end
    else
      return fs
    end
  end

  def get_pack_fmt (endian)
    case endian 
    when "big"
      return FMT_NET
    when "little"
      return FMT_VAX
    else
      raise "unknown endian '#{endian}'"
    end
  end

  class Record

    def initialize (data="", endian="little", fmt=nil)
      @io = StringIO.new(data)
      @fmt = fmt
      @endian = endian
    end

    def to_s
      return @io.string
    end

    def empty?
      return @io.eof?
    end

    def rest?
      return (not @io.eof?)
    end

    def read (*fmts)
      out = []
      while not fmts.empty?
        case fmt = fmts.shift
        when String
          list = []
          specs = fmt.scan(/(?:\d+|)(?:a\[\d+\]|\w)/)
          while not specs.empty?
            case specs.shift
            when /(\d+)?a\[(\d+)\]/
              ($1||1).to_i.times do 
                list.push(*@io.read($2.to_i).unpack("a#{$2}"))
              end
            when /(\d+)?a/
              ($1||1).to_i.times do 
                list.push(*@io.read(1).unpack("a"))
              end
            when /(\d+)?([dDEG])/
              ($1||1).to_i.times do 
                list.push(*@io.read(8).unpack(@fmt[$2]))
              end
            when /(\d+)?([lNVefFg])/
              ($1||1).to_i.times do 
                list.push(*@io.read(4).unpack(@fmt[$2]))
              end
            when /(\d+)?([nsv])/
              ($1||1).to_i.times do 
                list.push(*@io.read(2).unpack(@fmt[$2]))
              end
            else
              raise "invalid format for FortranSequential::Record#read"
            end
          end
          if list.size == 1
            out.push(list.first)
          else
            out.push(list)
          end
        when Integer
          n, tmpl = fmt, fmts.shift
          n.times do 
            out.push(tmpl.template.load_binary(@io))
          end
        when CArray
          tmpl = fmt
          if ENDIAN == @endian
            out.push(tmpl.template.load_binary(@io))
          else
            out.push(tmpl.template.load_binary(@io).swap_bytes!)
          end
        when CA::Struct
          if ENDIAN == @endian
            out.push(CScalar.new(fmt.class).load_binary(@io)[0])
          else
            out.push(CScalar.new(fmt.class).load_binary(@io).swap_bytes![0])
          end
        when Class
          if fmt < CA::Struct
            if ENDIAN == @endian
              out.push(CScalar.new(fmt).load_binary(@io)[0])
            else
              out.push(CScalar.new(fmt).load_binary(@io).swap_bytes![0])
            end
          else
            raise "invlaid argument (format string or CArray)"
          end
        else
          raise "invlaid argument (format string or CArray)"
        end 
      end
      if out.size == 1
        return out.first
      else
        return out
      end
    end

    def write (*fmts)
      while fmt = fmts.shift
        if fmt.is_a?(String)
          argv = fmts.shift
          unless argv.is_a?(Array)
            raise "argv should be array"
          end
          argv = argv.clone
        end
        case fmt
        when String
          specs = fmt.scan(/(?:\d+|)(?:a\[\d+\]|\w)/)
          while not specs.empty?
            case specs.shift
            when /(\d+)?a\[(\d+)\]/
              ($1||1).to_i.times do 
                @io.write [argv.shift].pack("a#{$2}")
              end
            when /(\d+)?([adDEGefFglNVnsv])/ 
              ($1||1).to_i.times do 
                @io.write [argv.shift].pack(@fmt[$2])
              end
            else
              raise "invalid format for FortranSequential::Record#write"
            end
          end
        when CArray
          if ENDIAN == @endian
            fmt.dump_binary(@io)
          else
            fmt.swap_bytes.dump_binary(@io)
          end
        when CA::Struct
          if RUBY_VERSION.to_f >= 1.9
            if ENDIAN == @endian
              @io.write fmt.encode.force_encoding("ASCII-8BIT")
            else
              @io.write fmt.swap_bytes.encode.force_encoding("ASCII-8BIT")
            end
          else
            if ENDIAN == @endian
              @io.write fmt.encode
            else
              @io.write fmt.swap_bytes.encode
            end
          end
        else
          raise "invlaid argument (format string or CArray)"
        end 
      end
    end

  end

  def eof?
    return @io.eof?
  end
  
end

class FortranSequentialReader < FortranSequential

  def initialize (io, opt={:endian=>nil})
    @io = io
    @endian = opt[:endian] || ENDIAN
    @fmt = get_pack_fmt(@endian)
  end
  
  def record (n=nil)
    if n 
      @io.rewind
      skip(n)
    end
    data = read
    if data
      rec = FortranSequential::Record.new(data, @endian, @fmt)
      if block_given?
        return yield(rec)
      else
        return rec
      end
    else
      return nil
    end
  end
  
  def skip (n=1)
    n.times do 
      unless @io.eof?
        length = @io.read(4).unpack(@fmt["l"]).first
        @io.pos += length
        if length != @io.read(4).unpack(@fmt["l"]).first
          raise "invalid record length (should be #{length})"
        end
      end
    end
  end
  
  def read (*dummy)
    if @io.eof?
      return nil
    else
      length = @io.read(4).unpack(@fmt["l"]).first
      data = @io.read(length)
      if data.length != length
        raise "record too short (record length should be #{length})"
      end
      if length != @io.read(4).unpack(@fmt["l"]).first
        raise "mismatched record length (should be #{length})"
      end
      return data
    end
  end
  
  def close
    @io.close
  end
  
end

class FortranSequentialWriter < FortranSequential

  def initialize (io, opt={:endian=>nil})
    @io = io
    @endian = opt[:endian] || ENDIAN
    @fmt = get_pack_fmt(@endian)
  end
  
  def record
    rec = FortranSequential::Record.new("", @endian, @fmt)
    if block_given?
      return yield(rec)
    else
      return rec
    end
  end
  
  def write (data)
    if data.respond_to?(:to_s)
      data = data.to_s
    end
    if RUBY_VERSION.to_f >= 1.9
      data = data.force_encoding("ASCII-8BIT")
    end
    @io.write [data.length].pack(@fmt["l"])
    @io.write data
    @io.write [data.length].pack(@fmt["l"])
  end
  
  def close
    @io.close
  end
  
end

def fortran_sequential_open (file, mode="r", opt={:endian=>nil}, &block)
  return FortranSequential.open(file, mode, opt, &block)
end

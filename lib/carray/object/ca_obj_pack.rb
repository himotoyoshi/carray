# ----------------------------------------------------------------------------
#
#  carray/object/ca_obj_pack.rb
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
# [ca1, ca2, ca3] => ca4
#
#
#


class CAPack < CAObject # :nodoc:

  def initialize (list, options={})
    @list   = list
    @rank   = options[:rank]
    unless @rank
      @rank = list.map{|m| m.rank}.min
    end
    @names  = options[:names] || [nil]*@list.size
    @dim    = guess_dim(list)
    @struct = guess_struct(list)
    super(@struct, @dim, :read_only=>true)
    freeze
  end

  private

  def fetch_index (idx)
    out   = @struct.new
    dummy = idx + [false]
    @struct.members.each_with_index do |name, i|
      out[name] = @list[i][*dummy]
    end
    return out
  end

  def copy_data (data)
    data.fields.zip(@list).each do |mem, d|
      mem[] = d
    end
  end

  def guess_dim (list)
    dim = nil
    list.each do |mem|
      case mem
      when CArray
        if mem.rank < @rank
          raise "mem.rank < @rank"
        else
          newdim = mem.dim[0, @rank]
        end
        if dim
          unless dim == newdim
            raise "dim != newdim"
          end
        else
          dim = newdim
        end
      end
    end
    return dim || [1]
  end

  def guess_struct (list)
    st = CA.struct(:pack=>1) { |s|
      list.each_with_index do |mem, i|
        name = @names[i]
        case mem
        when CArray
          if mem.rank == @rank
            s.member mem.data_type, name, :bytes=>mem.bytes ### anonymous member
          else
            dummy = Array.new(@rank){0} + [false]
            s.member mem[*dummy].to_ca, name                ### anonymous member
          end
        else
          raise "invalid object for CAPack"
        end
      end
    }
    return st
  end

end

class CArray
  def self.pack (*argv)
    return CAPack.new(argv)
  end
end

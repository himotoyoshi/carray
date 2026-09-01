#  Standalone example: CAObject that packs N CArrays together
#  ([ca1, ca2, ca3] => ca4, indexed by leading axis).
#
#  Run with:
#    ruby -Iext -Ilib examples/caobject/pack.rb
#
#  Copy this file into your own project to use the pattern.  Not shipped
#  as part of the CArray gem since 3.0.

require "carray"

class CAPack < CAObject

  def initialize (list, options={})
    @list   = list
    @ndim   = options[:ndim]
    unless @ndim
      @ndim = list.map{|m| m.ndim}.min
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
        if mem.ndim < @ndim
          raise "mem.ndim < @ndim"
        else
          newdim = mem.dim[0, @ndim]
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
    st = CArray.struct(:pack=>1) { |s|
      list.each_with_index do |mem, i|
        name = @names[i]
        case mem
        when CArray
          if mem.ndim == @ndim
            s.member mem.data_type, name, :bytes=>mem.bytes ### anonymous member
          else
            dummy = Array.new(@ndim){0} + [false]
            s.member mem[*dummy].copy, name                ### anonymous member
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

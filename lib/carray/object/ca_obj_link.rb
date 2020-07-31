# ----------------------------------------------------------------------------
#
#  carray/object/ca_obj_link.rb
#
#  This file is part of Ruby/CArray extension library.
#
#  Copyright (C) 2005-2020 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

require "carray"

class CALink < CAObject # :nodoc: 

  def initialize (*argv, &block)
    @evaluator = block
    @argv      = argv
    @args      = argv.map{|v| CScalar.new(v.data_type) }
    val = @evaluator.call(*argv)
    unless val.is_a?(CArray)
      val = CA_OBJECT(val)      
    end
    super(val.data_type, val.dim, :bytes=>val.bytes, :read_only=>true)
  end

  private

  def fetch_addr (addr)
    @argv.each_with_index do |v, i|
      case v
      when CScalar
        @args[i][] = v[]
      when CArray
        @args[i][] = v[addr]
      else
        @args[i][] = v
      end
    end
    return @evaluator.call(*@args)[0]
  end

  def copy_data (data)
    data[] = @evaluator.call(*@argv)
  end

  def create_mask
  end

end


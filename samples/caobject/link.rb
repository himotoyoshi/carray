#  Standalone example: CAObject that links multiple CArrays via a block
#  evaluator (= reactive view; reads recompute on demand).
#
#  Run with:
#    ruby -Iext -Ilib samples/caobject/link.rb
#
#  Copy this file into your own project to use the pattern.  Not shipped
#  as part of the CArray gem since 3.0.

require "carray"

class CALink < CAObject

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


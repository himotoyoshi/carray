# ----------------------------------------------------------------------------
#
#  carray/obsolete.rb
#
#  This file is part of Ruby/CArray extension library.
#
#  Copyright (C) 2005-2020 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

module CA
  TableMethods = CArray::TableMethods
end

class CArray
  
  ### obsolete methods

  def extend_as_table (column_names)
    warn "CArray#extend_as_table will be obsolete"
    self.extend CArray::TableMethods
    self.column_names = column_names
    self
  end

  # Returns the array eliminated all the duplicated elements.
  def duplicated_values
    warn "CArray#duplicated_values will be obsolete"
    if uniq.size == size
      return []
    else
      hash = {}
      list = []
      each_with_addr do |v, addr|
        if v == UNDEF
          next
        elsif hash[v]
          list << [v, addr, hash[v]]
          hash[v] += 1
        else
          hash[v] = 0
        end
      end
      return list
    end
  end

  def self.summation (*dim)
    warn "CArray.summation will be obsolete"
    out = nil
    first = true
    CArray.each_index(*dim) { |*idx|
      if first
        out = yield(*idx)
        first = false
      else
        out += yield(*idx)
      end
    }
    return out
  end
  
  def by (other)
    warn "CArray#by will be obsolete"
    case other
    when CArray
      return (self[nil][nil,:*]*other[nil][:*,nil]).reshape(*(dim+other.dim))
    else
      return self * other
    end
  end

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

  def replace_value (from, to)
    warn "CArray#replace_value will be obsolete"
    self[:eq, from] = to
    return self
  end
  
  def asign (*idx)
    warn "CArray#asign will be obsolete"
    self[*idx] = yield
    return self
  end
  
  def fa                               # :nodoc:
    warn "CArray#fa will be obsolete, use CArray#t"
    return self.t
  end

  def block_iterator (*argv)           # :nodoc:
    warn "CArray#block_iterator will be obsolete, use CArray#blocks"
    return blocks(*argv)
  end

  def window_iterator (*argv)          # :nodoc:
    warn "CArray#window_iterator will be obsolete, use CArray#windows"
    return windows(*argv)
  end

  def rotated (*argv)                  # :nodoc:
    warn "CArray#rotated will be obsolete, use CArray#rolled"
    argv.push({:roll => Array.new(ndim){1} })
    return shifted(*argv)
  end

  def rotate! (*argv)                  # :nodoc:
    warn "CArray#rotate! will be obsolete, use CArray#roll!"
    self[] = self.rolled(*argv)
    return self
  end

  def rotate (*argv)                   # :nodoc:
    warn "CArray#rotate will be obsolete, use CArray#roll"
    return self.rolled(*argv).to_ca
  end

  def select (&block)                  # :nodoc:
    warn "CArray#select will be obsolete"
    case block.arity
    when 1
      return self[*yield(self)]
    when -1, 0
      return self[*instance_exec(&block)]
    else
      raise
    end
  end

  def transform (type, dim, opt = {}) # :nodoc:
    warn("CArray#transform will be obsolete")
    return refer(type, dim, opt).to_ca
  end
  
  def classify (klass, outlier = nil)  # :nodoc:
    warn "CArray#classify will be obsolete"
    b = CArray.int32(*dim)
    f = CArray.boolean(*dim) { 1 }
    attach {
      (klass.elements-1).times do |i|
        r = f.and(self < klass[i+1])
        b[r] = i
        f[r] = 0
      end
      if outlier
        b[self < klass[0]] = outlier
        b[f] = outlier
      else
        b[self < klass[0]] = -1
        b[f] = klass.elements-1
      end
    }
    return b
  end



end

=begin

class Numeric
  
  [
    :boolean,
    :int8,
    :uint8,
    :int16,
    :uint16,
    :int32,
    :uint32,
    :int64,
    :uint64,
    :float32,
    :float64,
    :float128,
    :cmplx64,
    :cmplx128,
    :cmplx256,
    :byte,
    :short,
    :int,
    :float,
    :double,
    :complex,
    :dcomplex,
    :object
  ].each do |name|
    class_eval %{
      def #{name} ()
        warn "Numeric##{name} will be obsolete"
        CScalar.new(#{name.inspect}) {self}
      end
    }
  end

end

class CArray
  def histogram (klass)
    c = CArray.int32(klass.elements-1)
    f = CArray.boolean(*dim) { 1 }
    attach {
      k = 0
      r = f.and(self < klass[0])
      f[r] = 0
      (klass.elements-1).times do |i|
        r = f.and(self < klass[i+1])
        c[k] = r.count_true
        f[r] = 0
        k+=1
      end
    }
    return c
  end

  def self.load_from_file (filename, data_type, dim, opt={}) # :nodoc:
    raise "Sorry, CArray.load_from_file is depleted"
  end

end
=end
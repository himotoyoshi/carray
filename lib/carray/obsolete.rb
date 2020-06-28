
class CArray
  
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
    argv.push({:roll => Array.new(rank){1} })
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


=begin
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
=end

end

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
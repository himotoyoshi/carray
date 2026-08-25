#  CAClassIterator -- classification iterator used by CArray#classes
#  (yields per-equivalence-class kernels keyed off a sorted unique
#  classifier).  Autoloaded from lib/carray/iterator.rb on first
#  reference; only programs that call `ca.classes(...)` pay the load.

class CArray

  def classes (classifier=nil, &block)
    return CAClassIterator.new(self, classifier, &block)
  end

end

class CAClassIterator < CAIterator # :nodoc:

  UNIFORM_KERNEL = false

  def initialize (reference, classifier = nil, &block)
    @reference = reference
    @classifier = classifier || @reference.uniq.sort
    if @reference.has_data_class?
      @null = CARecord.new(@reference.data_class, 0)
    else
      @null = CArray.new(@reference.data_type, [0])
    end
    @table = {}
    @ndim = 1
    @dim  = [0]
    if @classifier.all_masked? or @classifier.size == 0
      @dim  = [0]
    else
#      @dim  = [@classifier.max+1]
      @dim  = [@classifier.size]
    end
    build_table(&block)
  end

  attr_reader :classifier, :table

  # Populate @table: for each classifier value, record the addresses of the
  # matching cells (or the addresses selected by the block when given).
  def build_table (&block)
    if block
      @classifier.each_with_addr do |v, i|
        @table[i] = block[v].where
      end
    else
      @classifier.each_with_addr do |v, i|
        @table[i] = @reference.eq(v).where
      end
    end
    return self
  end
  private :build_table

  def ndiming (&block)
    block ||= lambda {|a| a.size }
    values = self.to_a.map{|v| block[v] }.to_ca
    addrs  = values.sort_addr.reverse
    return CArray.tabulate([@classifier[addrs], values[addrs]])
  end

  def kernel_at_addr (addr, ref = nil)
    ref ||= @reference
    if @table[addr]
      return ref[@table[addr]]
    else
      return @null
    end
  end

  def kernel_at_index (idx, ref = nil)
    kernel_at_addr(idx[0], ref)
  end

end

require "carray"
require "carray/io/table"

module CA::TableMethods

  def to_dataframe (&block)
    return CADataFrame.new(self, &block)
  end
  
end

class CADataFrame

  def initialize (columns_or_table, row_index = nil, column_names = nil, &block)
    case columns_or_table
    when Hash
      columns = columns_or_table
      @column_names = columns.keys.map(&:to_s)
      @columns = normalize_columns(columns)
      @column_number = @column_names.size
      @row_number = @columns.first[1].size
      if @column_names.any?{ |key| @columns[key].size != @row_number }
        raise "column sizes mismatch"
      end
    when CArray
      table = columns_or_table
      if column_names
        @column_names = column_names.map(&:to_s)
      else
        @column_names = table.column_names.map(&:to_s)
      end
      @columns = table_to_columns(table)
      @column_number = @column_names.size
      @row_number = table.dim0
    else
      raise "unknown data"
    end
    if row_index
      @row_index = row_index.to_ca.object
    else
      @row_index = nil
    end
    @__methods__ = {}
    if block_given?
      arrange(&block)
    end
  end

  def __methods__
    return @__methods__
  end
  
  private

  def table_to_columns (table)
    new_columns = {}
    @column_names.each_with_index do |name, i|
      new_columns[name] = table[nil,i]
    end
    return new_columns
  end
  
  def normalize_columns (columns)
    new_columns = {}
    columns.each_key do |key|
      case columns[key]
      when CArray
        column = columns[key]
      when Array
        column = columns[key].to_ca
        if column.rank != 1
          list = columns[key].clone
          column = CArray.object(list.size).convert { list.shift }
        end
      else
        column = columns[key].to_ca
      end
      new_columns[key.to_s] = column
    end
    return new_columns
  end

  public

  attr_reader :columns, :column_names, :row_index, :column_number, :row_number

  def column_types
    return @columns_names.map{|name| @columns[name].data_type_name }
  end
  
  def each_column (&block)
    return @columns.each(&block)
  end
  
  def each_row (with_row_index: false, &block)
    if with_row_index and @row_index
      @row_number.times do |i|
        yield [@row_index[i]] + @columns.map{|n,c| c[i] }
      end      
    else
      @row_number.times do |i|
        yield @columns.map{|n,c| c[i] }
      end
    end
    return self
  end
    
  def method (hash)
    new_hash = {}
    hash.each do |key, value|
      new_hash[key.to_s] = value.to_s
    end
    @__methods__.update(new_hash)
  end

  def col (name_or_index)
    case name_or_index
    when Integer
      return @columns[@column_names[name_or_index]]
    when String, Symbol
      return @columns[name_or_index.to_s]
    end
  end

  def template (*args, &block)
    return @columns.first[1].template(*args, &block)
  end

  def row (idx)
    if @row_index
      addr = @row_index.search(idx)
      return @column_names.map{|name| @columns[name][addr]}.to_ca
    else
      return @column_names.map{|name| @columns[name][idx]}.to_ca
    end
  end

  def [] (row, col = nil)
    if row.is_a?(Integer)
      row = [row]
    end
    if col
      if col.is_a?(Integer)
        col = [col]
      end
      keys = @column_names.to_ca[col].to_a
      values = @columns.values_at(*keys)
      new_columns = {}
      keys.each do |key|
        new_columns[key] = @columns[key][row]
      end
      return CADataFrame.new(new_columns, @row_index ? @row_index[row] : nil)
    else
      new_columns = {}
      @column_names.each do |key|
        new_columns[key] = @columns[key][row]
      end
      return CADataFrame.new(new_columns, @row_index ? @row_index[row] : nil)
    end
  end

  def fill (*names, value)
    names.each do |name|
      @columns[name.to_s].fill(value)
    end
    return self
  end

  def arrange (&block)
    return Arranger.new(self).arrange(&block)    
  end

  def rename (name1, name2)
    if idx = @column_names.index(name1.to_s)
      @column_names[idx] = name2.to_s
      column = @columns[name1.to_s]
      @columns.delete(name1.to_s)
      @columns[name2.to_s] = column
    else
      raise "unknown column name #{name1}"
    end
  end

  def downcase 
    new_column_names = []
    new_columns = {}
    @column_names.each do |name|
      new_column_names << name.downcase
      new_columns[name.downcase] = @columns[name]
    end
    @column_names = new_column_names
    @columns = new_columns
    return self
  end

  def append (name, new_column = nil, &block)
    if new_column
      # do nothing
    elsif block
      new_column = instance_exec(&block)
    else
      new_column = @columns.first[1].template(:object)
    end
    unless new_column.is_a?(CArray)
      new_column = new_column.to_ca
    end
    new_columns = {}
    @column_names.each do |key|
      new_columns[key] = @columns[key]
    end
    new_columns[name.to_s] = new_column
    return CADataFrame.new(new_columns, @row_index)
  end

  def lead (name, new_column = nil, &block)
    if new_column
      # do nothing
    elsif block
      new_column = instance_exec(&block)
    else
      new_column = @columns.first[1].template(:object)
    end
    unless new_column.is_a?(CArray)
      new_column = new_column.to_ca
    end
    new_columns = {}
    new_columns[name.to_s] = new_column
    @column_names.each do |key|
      new_columns[key] = @columns[key]
    end
    return CADataFrame.new(new_columns, @row_index)
  end

  def vacant_copy
    new_columns = {}
    @column_names.each do |key|
      new_columns[key] = CArray.object(0)
    end
    return CADataFrame.new(new_columns)    
  end

  def merge (*args)
    return CADataFrame.merge(self, *args)
  end


  def execute (&block)
    return instance_exec(&block)
  end
  
  def calculate (label, &block)
    hash = {}
    @column_names.each do |name|
      begin
        if block
          hash[name] = [yield(name, @columns[name])]
        else
          hash[name] = [@columns[name].send(label.intern)]
        end
      rescue
        hash[name] = [UNDEF]
      end
    end
    return CADataFrame.new(hash, [label])
  end

  def resample (&block)
    new_columns = {}
    @column_names.each do |name|
      begin
        new_columns[name] = yield(name, @columns[name])
      rescue
      end
    end
    return CADataFrame.new(new_columns)
  end

  def select (*names, &block)
    if names.empty?
      names = @column_names
    end
    if block
      row = instance_exec(&block)
    else
      row = nil
    end
    new_columns = {}
    names.map(&:to_s).each do |name|
      new_columns[name] = @columns[name][row]
    end
    return CADataFrame.new(new_columns, @row_index ? @row_index[row] : nil)
  end

  def eliminate (*names)
    if names.empty?
      return self
    end
    names = names.map(&:to_s)
    new_columns = {}
    @column_names.each do |name|
      unless names.include?(name)
        new_columns[name] = @columns[name]
      end
    end
    return CADataFrame.new(new_columns, @row_index)    
  end

  def matchup (keyname, reference)
    key = @columns[keyname.to_s]
    idx = reference.matchup(key)
    new_columns = {}
    @column_names.each do |name|
      if name == keyname
        new_columns[name] = reference
      else
        new_columns[name] = @columns[name].project(idx)
      end
    end
    if @row_index
      new_row_index = @row_index.project(idx).unmask(nil)
    else
      new_row_index = nil
    end
    return CADataFrame.new(new_columns, new_row_index) {
      self.send(keyname)[] = reference
    }
  end
  
  def reorder (&block)
    index = instance_exec(&block)
    new_columns = {}
    @column_names.each do |name|
      new_columns[name] = @columns[name][index]
    end
    return CADataFrame.new(new_columns, @row_index ? @row_index[index] : nil)    
  end

  def order_by (*names, &block)
    if names.empty?
      if block
        ret = instance_exec(&block)
        case ret
        when CArray
          list = [ret]
        when Array
          list = ret
        end
      end
    else
      list = @columns.values_at(*names.map{|s| s.to_s})
    end
    return reorder { CA.sort_addr(*list) }
  end

  def reverse
    new_columns = {}
    @column_names.each do |name|
      new_columns[name] = @columns[name].reverse
    end
    return CADataFrame.new(new_columns, @row_index ? @row_index.reverse : nil)    
  end

  def transpose (header = nil)
    if header
      column_names = header.map(&:to_s)
    else
      if @row_index
        column_names = @row_index.convert(:object) {|v| v.to_s }
      else
        column_names = CArray.object(@row_number).seq("a",:succ)
      end
    end
    return CADataFrame.new(ca.transpose, @column_names.to_ca, column_names)
  end

  def histogram (name, scale = nil, options = nil)
    if scale.nil?
      return group_by(name).table{ { :count => col(name).count_valid } }
    else
      if options
        hist = CAHistogram.int(scale, options)
      else
        hist = CAHistogram.int(scale)      
      end
      hist.increment(@columns[name.to_s])
      hash = {
        name.to_s => hist.midpoints[0],
        "#{name}_L".to_s => scale[0..-2],
        "#{name}_R".to_s => scale.shift(-1)[0..-2],
        :count => hist[0..-2].to_ca,
      }
      return CADataFrame.new(hash)
    end
  end

  def classify (name, scale = nil, opt = {})
    if not scale
      column = @columns[name.to_s]
      mids   = column.uniq
      mapper = {}
      mids.each_with_index do |v,i|
        mapper[v] = i
      end
      cls = columns.convert(:int32) {|v| mapper[v] }
      hash = {
        "#{name}_M" => mids,
        "#{name}_L" => mids,
        "#{name}_R" => mids,
        "#{name}_CLASS" => cls        
      }
    else
      option = {
        :include_upper  => false,
        :include_lowest => true,
        :offset => 0,
      }.update(opt)
      column = @columns[name.to_s]
      cls = scale.bin(column, 
                      option[:include_upper],
                      option[:include_lowest], 
                      option[:offset])
      mids = ((scale + scale.shifted(-1))/2)[0..-2].to_ca
      left = scale[0..-2]
      right = scale.shift(-1)[0..-2]
      hash = {
        "#{name}_M" => mids.project(cls).to_ca,
        "#{name}_L" => left.project(cls).to_ca,
        "#{name}_R" => right.project(cls).to_ca,
        "#{name}_CLASS" => cls
      }
    end
    return CADataFrame.new(hash)
  end

  def suffix (suf)
    new_columns = {}
    @column_names.each do |name|
      new_name = (name.to_s + suf).to_s
      new_columns[new_name] = @columns[name]
    end
    return CADataFrame.new(new_columns, @row_index)        
  end

  def ca (*names)
    if names.empty?
      return CADFArray.new(@column_names, @columns)
    else
      return CADFArray.new(names.map(&:to_s), @columns)
    end
  end
  
  def to_ca (*names)
    return ca(*names).to_ca
  end
  
  def to_hash (name1, name2)
    return CArray.join([@columns[name1.to_s], @columns[name2.to_s]]).to_a.to_h
  end
  
  def ascii_table (rowmax = :full)
    if @row_index
      namelist = [""] + @column_names
      tbl = CADFArray.new(namelist, @columns.clone.update("" => @row_index))
    else
      namelist = @column_names
      tbl = to_ca
    end
    if rowmax.is_a?(Integer) and @row_number > rowmax
      list = tbl[0..(rowmax/2),nil].to_a
      list.push namelist.map { "..." }
      list.push *(tbl[-rowmax/2+1..-1,nil].to_a)
      tbl = list.to_ca
    end
    datastr = tbl.convert {|c| __obj_to_string__(c) }.unmask("")
    datamb  = datastr.convert(:boolean, &:"ascii_only?").not.sum(0).ne(0)
    namemb  = namelist.to_ca.convert(:boolean) {|c| c.to_s.ascii_only? }.eq(0)
    mb      = datamb.or(namemb)
    namelen = namelist.map(&:length).to_ca
    datalen = datastr.convert(&:length)
    if mb.max == 0
      if datalen.size == 0
        lengths  = namelen.to_a
      else
        lengths  = datalen.max(0).pmax(namelen).to_a
      end
      hrule  = "-" + lengths.map {|len| "-"*len}.join("--") + "-"
      header = " " + 
               [namelist, lengths].transpose.map{|name, len| 
                                            "#{name.to_s.ljust(len)}" }.join("  ") + " "
      ary = [hrule, header, hrule]
			if datalen.size > 0
	      datastr[:i,nil].each_with_index do |blk, i|
	        list = blk.flatten.to_a
	        ary << " " + [list, lengths].transpose.map{|value, len| 
	                                            "#{value.ljust(len)}"}.join("  ") + " "
	      end
			end
      ary << hrule
      return "DataFrame: rows#=#{@row_number}: \n" + ary.join("\n")
    else
      namewidth  = namelist.to_ca.convert{|c| __strwidth__(c.to_s) }
      if datalen.size == 0
        maxwidth   = namewidth
      else
        datawidth  = datastr.convert{|c| __strwidth__(c.to_s) }
        maxwidth   = datawidth.max(0).pmax(namewidth)
      end
      len = maxwidth[:*,nil] - datawidth + datalen 
      hrule  = "-" + maxwidth.map {|len| "-"*len}.join("--") + "-"
      header = " " + 
               [namelist, maxwidth.to_a].transpose.map{|name, len| 
                                            "#{name.to_s.ljust(len-__strwidth__(name.to_s)+name.to_s.length)}" }.join("  ") + " "
      ary = [hrule, header, hrule]
			if datalen.size > 0
	      datastr[:i,nil].each_with_addr do |blk, i|
	        list = blk.flatten.to_a
	        ary << " " + list.map.with_index {|value, j|
	                  "#{value.ljust(len[i,j])}"}.join("  ") + " "
	      end
			end
      ary << hrule
      return "DataFrame: row#=#{@row_number}: \n" + ary.join("\n")
    end
  end

  def __obj_to_string__ (obj)
    case obj
    when Float
      "%.6g" % obj
    else
      obj.to_s
    end
  end

  def __strwidth__ (string)
    if string.ascii_only?
      return string.length
    else
      return string.each_char.inject(0){|s,c| s += c.bytesize > 1 ? 2 : 1 }
    end
  end

  def inspect
    return ascii_table(10)
  end

  def to_s
    return ascii_table
  end
  
  def to_ary
    return [to_s]
  end

  def to_csv (with_row_index: true)
    if @row_index and with_row_index
      namelist = [""] + @column_names
      tbl = CADFArray.new(namelist, @columns.clone.update("" => @row_index))
    else
      namelist = @column_names
      tbl = ca
    end
    output = []
    output << namelist.map(&:to_s).join(",")
    output << tbl.to_csv
    return output.join("\n")
  end

  def to_xlsx (filename, sheet_name: 'Sheet1', with_row_index: true, &block)
    require "axlsx"
    xl = Axlsx::Package.new
    xl.use_shared_strings = true
    sheet = xl.workbook.add_worksheet(name: sheet_name)
    sheet.add_row(column_names)
    each_row(with_row_index: with_row_index) do |list|
      sheet.add_row(list)
    end
    if block_given?
      yield sheet
    end
    xl.serialize(filename)
  end

  def method_missing (name, *args)
    if args.size == 0 
      name = name.to_s
      if @column_names.include?(name) 
        return @columns[name]
      elsif @column_names.include?(name.gsub(/_/,'.')) ### For R
        return @columns[name.gsub(/_/,'.')]
      elsif @__methods__.include?(name)
        return @columns[@__methods__[name]]
      end
    end
    super
  end

end

#############################################################
# 
# ARRANGER
#
#############################################################


class CADataFrame

  class Arranger
    
    def initialize (dataframe)
      @dataframe = dataframe
    end
    
    def arrange (&block)
      instance_exec(&block)
      return @dataframe      
    end

    private
    
    def column_names
      return @dataframe.column_names
    end

    def row_number
      return @dataframe.row_number
    end

    def method (hash)
      @dataframe.method(hash)
    end

    def timeseries (name, fmt = "%Y-%m-%d %H:%M:%S")
      @dataframe.columns[name.to_s] = @dataframe.columns[name.to_s].strptime(fmt)
    end

    def type (type, name, mask = :novalue)
      @dataframe.columns[name.to_s] = @dataframe.columns[name.to_s].to_type(type)
      if mask != :novalue
        @dataframe.columns[name.to_s].maskout!(options[:maskout])
      end
    end

    def eliminate (*names)
      if names.empty?
        return self
      end
      names = names.map(&:to_s)
      @dataframe.column_names.each do |name|
        if names.include?(name)
          @dataframe.columns.delete(name)
          @dataframe.column_names.delete(name)
        end
      end
    end

    def template (*args, &block)
      return @dataframe.template(*args, &block)
    end
  
    def double (*names)
      names.flatten.each do |name|
        type(:double, name)
      end
    end

    def int (*names)
      names.flatten.each do |name|
        type(:int, name)
      end
    end

    def maskout (value, *names)
      names.flatten.each do |name|
        @dataframe.columns[name.to_s].maskout!(value)
      end
    end

    def unmask (value, *names)
      names.flatten.each do |name|
        @dataframe.columns[name.to_s].unmask(value)
      end
    end
  
    def col (name)
      return @dataframe.col(name)
    end
    
    def append (name, new_column)
      if new_column
        # do nothing
      else
        new_column = @dataframe.columns.first[1].template(:object)
      end
      unless new_column.is_a?(CArray)
        new_column = new_column.to_ca
      end
      @dataframe.columns[name.to_s] = new_column
      @dataframe.column_names.push(name.to_s)
    end

    def lead (name, new_column)
      if new_column
        # do nothing
      else
        new_column = @dataframe.columns.first[1].template(:object)
      end
      unless new_column.is_a?(CArray)
        new_column = new_column.to_ca
      end
      @dataframe.columns[name.to_s] = new_column
      @dataframe.column_names.unshift(name.to_s)
    end
    
    def rename (name1, name2)
      if idx = @dataframe.column_names.index(name1.to_s)
        @dataframe.column_names[idx] = name2.to_s
        column = @dataframe.columns[name1.to_s]
        @dataframe.columns.delete(name1.to_s)
        @dataframe.columns[name2.to_s] = column
      else
        raise "unknown column name #{name1}"
      end
    end

    def downcase 
      @dataframe.downcase
    end

    def classify (name, scale, opt = {})
      return @dataframe.classify(name, scale, opt)
    end
    
    def map (mapper, name_or_column)
      case name_or_column
      when String, Symbol
        name = name_or_column
        column = @dataframe.columns[name.to_s]
      when CArray
        column = name_or_column
      when Array
        column = name_or_column.to_ca
      else
        raise "invalid argument"
      end
      case mapper
      when Hash
        return column.convert(:object) {|v| hash[v] }
      when CArray
        return mapper.project(column)
      when Array
        return mapper.to_ca.project(column)        
      end
    end
    
    def method_missing (name, *args)
      if args.size == 0 
        if @dataframe.column_names.include?(name.to_s) 
          return @dataframe.columns[name.to_s]
        elsif @dataframe.__methods__.include?(name.to_s)
          return @dataframe.columns[@dataframe.__methods__[name.to_s]]
        end
      end
      super
    end
    
  end
  
end

#############################################################
# 
# Class methods
#
#############################################################

class CADataFrame

  def self.load_sqlite3 (*args)
    return CArray.load_sqlite3(*args).to_dataframe.arrange{ maskout nil, *column_names }
  end

  def to_sqlite3 (*args)
    ca = self.ca.to_ca
    ca.extend CA::TableMethods
    ca.column_names = column_names
    ca.to_sqlite3(*args)
  end

  def self.load_csv (*args, &block)
    return CArray.load_csv(*args, &block).to_dataframe.arrange{ maskout nil, *column_names }
  end

  def self.from_csv (*args, &block)
    return CArray.from_csv(*args, &block).to_dataframe.arrange{ maskout nil, *column_names }
  end

  def self.merge (*args)
    ref = args.first
    new_columns = {}
    args.each do |table|
      table.column_names.each do |name|
        new_columns[name] = table.col(name)
      end
    end
    return CADataFrame.new(new_columns, ref.row_index)
  end
  
  def self.concat (*args)
    ref = args.first
    column_names = ref.column_names
    new_columns = {}
    column_names.each do |name|
      list = args.map{|t| t.col(name) }
      data_type = list.first.data_type
      new_columns[name] = CArray.bind(data_type, list, 0)   
    end
    if args.map(&:row_index).all?
      new_row_index = CArray.join(*args.map(&:row_index))
    else
      new_row_index = nil
    end
    return CADataFrame.new(new_columns, new_row_index)
  end


end

#############################################################
# 
# CADFArray
#
#############################################################

class CADFArray < CAObject # :nodoc:

  def initialize (column_names, columns)
    @column_names = column_names
    @columns = columns
    dim = [@columns[@column_names.first].size, @column_names.size]
    extend CA::TableMethods
    super(:object, dim, :read_only=>true)
    __create_mask__
  end
  
  attr_reader :column_names

  def fetch_index (idx)
    r, c = *idx
    name = @column_names[c]
    return @columns[name][r]
  end

  def copy_data (data)
    @column_names.each_with_index do |name, i|
      data[nil,i] = @columns[name].value
    end
  end

  def create_mask
  end

  def mask_fetch_index (idx)
    r, c = *idx
    name = @column_names[c]
    if @columns[name].has_mask?
      return @columns[name].mask[r]
    else
      return 0
    end
  end

  def mask_copy_data (data)
    @column_names.each_with_index do |name, i|
      if @columns[name].has_mask?
        data[nil,i] = @columns[name].mask
      end
    end
  end

end


#############################################################
# 
# GROUPING
#
#############################################################

class CADataFrame
  
  def group_by (*names)
    if names.size == 1
      return CADataFrameGroup.new(self, names[0])
    else
      return CADataFrameGroupMulti.new(self, *names)
    end
  end
  
end

class CADataFrameGroup

  def initialize (dataframe, name)
    @dataframe = dataframe
    case name
    when Hash
      name, list = name.first
      @column = @dataframe.col(name)
      @keys = list.to_ca
    else
      @column = @dataframe.col(name)
      @keys = @column.uniq.sort
    end
    @name = name.to_s
    @addrs = {}
    @keys.each do |k|
      @addrs[k] = @column.eq(k).where
    end
  end

  def table (&block)
    hashpool = []
    @keys.each do |k|
      hashpool << @dataframe[@addrs[k]].execute(&block)
    end
    columns = {@name=>@keys}
    hashpool.each_with_index do |hash, i|
      hash.each do |key, value|
        columns[key] ||= []
        columns[key][i] = value
      end
    end
    return CADataFrame.new(columns)
  end

	def calculate (label, &block)
    new_columns = {@name=>@keys}
		@dataframe.each_column do |name, column|
      if name == @name
        next
      end
      new_columns[name] = CArray.object(@keys.size) { UNDEF }
      @keys.each_with_index do |k, i|
        begin
          if block
            new_columns[name][i] = yield(name, column[@addrs[k]])
          else
            new_columns[name][i] = column[@addrs[k]].send(label.intern)
          end
        rescue
        end
      end
    end
    return CADataFrame.new(new_columns)
	end

  def [] (group_value)
    if map = @addrs[group_value]
      return @dataframe[map]
    else
      return @dataframe.vacant_copy
    end
  end


end

class CADataFrameGroupMulti
  
  def initialize (dataframe, *names)
    @rank = names.size
    @dataframe = dataframe
    @names = []
    @column = []
    @keys = []
    names.each_with_index do |name, i|    
      case name
      when Hash
        name, list = name.first
        @column[i] = @dataframe.col(name)
        @keys[i] = list.to_ca
      else
        @column[i] = @dataframe.col(name)
        @keys[i] = @column[i].to_ca.uniq.sort
      end
      @names[i] = name
    end
    @addrs = {}
    each_with_keys do |list|
      flag = @column[0].eq(list[0])
      (1...@rank).each do |i|
        flag &= @column[i].eq(list[i])
      end
      @addrs[list] = flag.where
    end
  end

  def each_with_keys (&block)
    @keys[0].to_a.product(*@keys[1..-1].map(&:to_a)).each(&block)    
  end
  
  def table (&block)
    hashpool = []
    each_with_keys do |list|
      hashpool << @dataframe[@addrs[list]].execute(&block) 
    end
    columns = {}
    @names.each do |name|
      columns[name] = []
    end
    each_with_keys.with_index do |list,j|
      @names.each_with_index do |name,i|
        columns[name][j] = list[i]
      end
    end
    hashpool.each_with_index do |hash, i|
      hash.each do |key, value|
        columns[key] ||= []
        columns[key][i] = value
      end
    end
    return CADataFrame.new(columns)
  end

  def [] (group_value)
    if map = @addrs[group_value]
      return @dataframe[map]
    else
      return @dataframe.vacant_copy
    end
  end
  
  def each 
    each_with_keys do |key|
      yield key, @dataframe[@addrs[key]]
    end
  end
  
end


#############################################################
# 
# PIVOT TABLE
#
#############################################################

class CADataFrame
  
  def pivot (name1, name2)
    return CADataFramePivot.new(self, name1, name2)
  end
  
end

class CADataFramePivot
  
  def initialize (dataframe, name1, name2)
    @dataframe = dataframe
    case name1
    when Hash
      name1, list = name1.first
      @column1 = @dataframe.col(name1)
      @keys1 = list.to_ca
    else
      @column1 = @dataframe.col(name1)
      @keys1 = @column1.uniq.sort  
    end
    case name2
    when Hash
      name2, list = name2.first
      @column2 = @dataframe.col(name2)
      @keys2 = list
    else
      @column2 = @dataframe.col(name2)
      @keys2 = @column2.uniq.sort
    end
    @addrs = {}
    @keys1.each do |k1|
      @keys2.each do |k2|
        @addrs[[k1,k2]] = (@column1.eq(k1) & @column2.eq(k2)).where
      end
    end
  end
  
  def table (&block)
    columns = {}
    @keys2.each do |k2|
      columns[k2] = CArray.object(@keys1.size) { UNDEF }
    end
    @keys1.each_with_index do |k1, i|
      @keys2.each do |k2|
        columns[k2][i] = @dataframe[@addrs[[k1,k2]]].execute(&block)
      end
    end
    return CADataFrame.new(columns, @keys1)
  end
  
end




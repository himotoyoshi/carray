require "rsruby"
require "rsruby/erobj"
require "carray"

class RSRuby
  
  #Converts a String representing a 'Ruby-style' R function name into a 
  #String with the real R name according to the rules given in the manual.
  def RSRuby.convert_method_name (name)
    if name.length > 1 and name[-1].chr == '_' and name[-2].chr != '_'
      name = name[0..-2]
    end
    name = name.gsub(/__/,'<-')
    name = name.gsub(/_/, '.')
    return name
  end
  
end

def R (expr = nil, hash = {}, &block)
  if block
    if expr
      raise "don't give both of block and expresion"
    else
      R.instance_exec(&block)
    end
  else
    return R.call(expr, hash)
  end
end

def R! (expr = nil, hash = {}, &block)
  if block
    if expr
      raise "don't give both of block and expresion"
    else
      R.instance_exec(&block)
    end
	elsif expr.is_a?(Hash)
		expr.each do |name, value|
			R.instance.assign name.to_s, value
		end
  else
    return R.exec(expr, hash)
  end
end

module R

  class Receiver < ::ERObj

    def initialize (klass, x)
      @classname  = klass
      @attributes = R(%{ attributes(obj) },:obj=>x)
      super(x)
    end

    attr_reader :attributes, :robj

    def [] (sym = nil)
      if sym
        name = sym.to_s
        name = name.gsub(/_/, '.')
        begin
          ret = @r['$'].call(@robj, name)
        rescue RException
          ret = @attributes[name]
        end
        return __converter__(ret)
      else
        return __converter__(to_ruby)
      end
    end

    def __converter__ (arg)
      case arg
      when Array
        return arg.to_ca.map!{|v| __converter__(v) }
      when Hash
        new_hash = {}
        arg.each do |k,v|
          new_hash[k] = __converter__(v)
        end
        return new_hash
      when RObj
        return R::CONVERTER[arg]
      else
        return arg
      end
    end
        
    def method
      return self[:method]
    end

    def inspect
      return "<R:Receiver: class=#{@classname} \n" \
             "             attributes=#{@attributes.inspect} \n" \
             "             data=#{to_ruby} >"
    end

    def method_missing (sym, *args)
      if args.empty?
        return self[sym]
      else
        super
      end
    end
      
    def to_ary
      return [self.to_s]
    end
      
  end

  CONVERSION_TABLE = {
    "data.frame" => lambda{ |x| CADataFrame.from_R_data_frame(x) },
    "ts" => lambda{ |x| R::TimeSeries.new(x) },
  }

  CONVERTER = lambda{|x| 
    case x
    when RObj
      klass = @r.eval_R("class").call(x)
      if CONVERSION_TABLE.has_key?(klass)
        CONVERSION_TABLE[klass][x]
      else
        case val = x.to_ruby
        when Numeric, String
          val
        when Hash, NilClass
          Receiver.new(klass, x)
        when Array
          val = val.to_ca
          case klass
          when "character", "factor"
            val = val.maskout!(R.NA_character_)
          when "integer"
            val = val.maskout!(R.NA_integer_).int32
          when "numeric"
            val = val.maskout!(R.NA_real_).double
          end
          val
        else
          val
        end
      end
    else 
      x
    end
  }

  def self.run
    if @r
      return nil
    end
    @r = RSRuby.instance
    RSRuby.set_default_mode(RSRuby::PROC_CONVERSION)
    @r.class_table['data.frame'] = lambda{|x| ERObj.new(x) }
    @r.class_table['matrix'] = lambda{|x| ERObj.new(x) }
    @r.proc_table[lambda{|x| true }] = CONVERTER
    @NA_integer_   = R %{ NA_integer_ }
    @NA_real_      = R %{ NA_real_ }
    @NA_character_ = R %{ NA_character_ }
    ObjectSpace.define_finalizer(self, proc{ @r.shutdown })
    return nil
  end
  
  def self.stop
    @r.shutdown
    @r = nil
  end

  class << self
    attr_reader :NA_integer_, :NA_real_, :NA_character_
  end

  def self.instance
    return @r
  end

  def self.exec (expr, hash = {})
    hash.each do |name, value|
      @r.assign(name.to_s, __converter__(value))
    end
    return @r.eval_R(expr)
  end

  def self.call (expr, hash = {})
    names = ["DU33Y"]
    args  = [0]
    hash.each do |name, value|
      names.push(name.to_s)
      args.push(__converter__(value))
    end
    expr = "function (#{names.join(",")}) {" + expr + "}"
    return @r.eval_R(expr).call(*args)
  end

  def self.__converter__ (arg)
    case arg
    when Symbol
      return arg.to_s
    when CArray
      return __converter__(arg.as_r)
    when CADataFrame
      return arg.as_r
    when Array
      return arg.map{|v| __converter__(v) }
    when Hash
      new_hash = {}
      arg.each do |k,v|
        new_hash[k] = __converter__(v)
      end
      return new_hash
    else
      return arg
    end
  end

  def self.method_missing (sym, *args)
    if args.empty? and sym.to_s[-1] == "!"
      return @r.send(sym.to_s[0..-2].intern).call()
    elsif args.size == 1 and sym.to_s[-1] == "="
      return @r.assign(sym.to_s[0..-2], __converter__(args[0]))
    else
      return @r.send(sym, *args.map{|v| __converter__(v)})
    end
  end

end

class CArray

  def guess_column_type_for_R 
    if is_a?(CArray)
      if integer?
        "integer"
      elsif float?
        "numeric"
      elsif object?
        notmasked = self[:is_not_masked].to_ca
        if notmasked.convert(:boolean){|v| v.is_a?(Integer) }.all_equal?(1)
          "integer"
        elsif notmasked.convert(:boolean){|v| v.is_a?(Numeric) }.all_equal?(1)
          "numeric"
        elsif notmasked.convert(:boolean){|v| v.is_a?(String) }.all_equal?(1)
          "character"
        else
          "unknown"
        end
      end
    else
      raise "invalid column name"
    end
  end

  def as_r
    if has_mask?
      case guess_column_type_for_R
      when "integer"
        out = unmask_copy(R.NA_integer_)
      when "numeric"
        out = unmask_copy(R.NA_real_)
      else
        out = unmask_copy(R.NA_character_)
      end
		else
			out = self
    end
	  if rank == 1
      return out.to_a
    elsif rank == 2
			begin
		    mode = RSRuby.get_default_mode
	      RSRuby.set_default_mode(RSRuby::NO_CONVERSION)
	      return R.matrix(out.flatten.to_a, :nrow=>dim0)
	    ensure
	      RSRuby.set_default_mode(mode)
	    end
		else
			return out.to_a
		end
  end

end

class CADataFrame

  def self.from_R_data_frame (obj)
    r = R.instance
    RSRuby.set_default_mode(RSRuby::PROC_CONVERSION)
    r.proc_table[lambda{|x| true }] = R::CONVERTER
    dataframe = obj
    column_names = r.colnames(obj).to_a
    column_names = [column_names].flatten
    row_names = r.attr(obj, 'row.names')
    columns = {}
    column_names.each do |name|
      value = r['$'].call(obj, name.to_s)
      case value
      when CArray
        columns[name] = value
      when Array
        columns[name] = value.to_ca        
      else
        columns[name] = [value].to_ca
      end
    end
    column_names.each do |name|
      column = columns[name]
      column.maskout!(nil)
    end
    return CADataFrame.new(columns, row_names ? row_names.to_ca : nil)
  end

  def as_r
    r = R.instance
    new_columns = {}
    @column_names.each do |name|
      column = @columns[name]
      if column.has_mask?
        case column.guess_column_type_for_R
        when "integer"
          column = column.unmask_copy(R.NA_integer_)
        when "numeric"
          column = column.unmask_copy(R.NA_real_)
        else
          column = column.unmask_copy(R.NA_character_)
        end
      end
      new_columns[name] = R.__converter__(column.to_a)
    end
    mode = RSRuby.get_default_mode
     RSRuby.set_default_mode(RSRuby::NO_CONVERSION)
    return r.as_data_frame(:x => new_columns)
  ensure
    RSRuby.set_default_mode(mode)
  end

end

class R::TimeSeries < ERObj
  
  def start
    return R.start(self)
  end
  
  def end
    return R.end(self)
  end
  
  def frequency
    return R.frequency(self)
  end
  
  def length
    return R.length(self)
  end
    
end



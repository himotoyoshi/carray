require "pg"
require "carray"

class CArray
  
  def self.load_pg (expr, *args)
    case expr
    when Hash
      opts = expr
      sql, *vars = *args
      db = PG.connect(opts)
      begin
        result = db.async_exec(sql, *vars)
        names = result.fields
        table = result.values
      rescue Interrupt
        db.cancel
        raise 
      ensure
        db.finish       
      end
    when PG::Result
      result = expr
      names = result.fields
      table = result.values
    when PG::Connection
      db = expr
      sql, *vars = *args
      begin
        result = db.async_exec(sql, *vars)
        names = result.fields
        table = result.values
      rescue Interrupt
        db.cancel
        raise
      end
    else
      raise "invalid 1st arg"
    end
    table = table.to_ca
    table.instance_exec { 
      @result = result
      @names  = names
    }
    class << table
      attr_reader :names, :result
      def column (name)
        if self.size == 0
          if name.is_a?(Integer)
            return CA_OBJECT([])
          elsif @names
            if i = @names.index(name.to_s)
              return CA_OBJECT([])
            end
          end
          return nil          
        else
          if name.is_a?(Integer)
            return self[false, name]
          elsif @names
            if i = @names.index(name.to_s)
              return self[false, i]
            end
          end
          return nil
        end
      end
    end
    return table
  end

  def unescape_bytea (type, subdim = nil)
    bytes = CArray.sizeof(type)
    max_bytesize = self.convert{|v| v ? PG::Connection.unescape_bytea(v).bytesize : 0}.max
    unless subdim
      subdim = [max_bytesize/bytes]
    end
    out = CArray.new(type, dim + subdim)
    needed_bytes = out.elements/self.elements*bytes
    ref = out.refer(:fixlen, dim, :bytes=>needed_bytes)
    if needed_bytes == max_bytesize
      ref.load_binary self.convert {|v| PG::Connection.unescape_bytea(v) }.join
    else
      self.each_addr do |addr|
        if self[addr]
          text = PG::Connection.unescape_bytea(self[addr])
          ref[[addr]].load_binary PG::Connection.unescape_bytea(self[addr])
        else
          out[addr,false] = UNDEF
        end
      end
    end
    return out
  end
  
  def escape_bytea (db)
    return db.escape_bytea(self.to_s)
  end

end


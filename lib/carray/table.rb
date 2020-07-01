
class CArray
  
  module TableMethods

    attr_reader :column_names

    def column_names= (list)
      if self.empty?
        return
      elsif list.nil? 
        return
      elsif list.empty? 
        return
      elsif list and list.size != dim1
        raise "column_names list size is invalid (#{list.size} <=> #{dim1} )"
      else
        @column_names = list
      end
    end

    def column (name)
      if name.is_a?(Integer)
        return self[false, name]
      elsif @column_names
        case name
        when Symbol
          if i = @column_names.index(name) or i = @column_names.index(name.to_s) 
            return self[false, i]
          end          
        when String
          if i = @column_names.index(name) or i = @column_names.index(name.intern) 
            return self[false, i]
          end
        end
      end
      return nil
    end

    def row (i)
      keys = @column_names || (0...dim0).to_a
      output = {}
      data = self[i, nil]
      keys.each_with_index do |key, j|
        output[key] = data[j]
      end
      return output
    end

    def rows (arg)
      table = self[arg, nil].to_ca
      table.extend(CA::TableMethods)
      table.column_names = @column_names
      return table
    end

    def select
      idx = yield(self)
      case idx.data_type
      when CA_BOOLEAN
        idx = idx.where
      end
      return rows(+idx)
    end

  end
  
end


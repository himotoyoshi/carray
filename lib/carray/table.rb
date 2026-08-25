
class CArray
  
  # Column-name support for a 2-D CArray used as a table: an ordered name
  # list alongside the data, plus name-based column access.
  module TableMethods

    # @!attribute [r] column_names
    #   @return [Array<Symbol, String>, nil] the assigned column
    #     names, or `nil` when none have been set.
    attr_reader :column_names

    # @overload column_names=(list)
    #   Sets the column-name list for `self`. `list` must have length
    #   equal to `dim1` (the second axis size); `nil` and empty lists
    #   are silently ignored.
    #   @param list [Array<Symbol, String>, nil] column names.
    #   @return [Array<Symbol, String>, nil] the assigned list.
    #   @raise [RuntimeError] when `list.size != dim1`.
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

    # @overload column(name)
    #   Returns the column view identified by `name`. Integer names
    #   index the second axis directly; Symbol and String names look
    #   up the position in {#column_names}. Returns `nil` when the
    #   name is unknown.
    #   @param name [Integer, Symbol, String] column identifier.
    #   @return [CArray, nil] column view or `nil` when unknown.
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

    # @overload row(i)
    #   Returns the `i`-th row as a Hash keyed by {#column_names}
    #   (falling back to 0-based Integer keys when none are set).
    #   @param i [Integer] row index.
    #   @return [Hash]
    def row (i)
      keys = @column_names || (0...dim0).to_a
      output = {}
      data = self[i, nil]
      keys.each_with_index do |key, j|
        output[key] = data[j]
      end
      return output
    end

    # @overload rows(arg)
    #   Returns a fresh table copy holding the rows selected by `arg`,
    #   extended with {TableMethods} and carrying `self`'s
    #   {#column_names}.
    #   @param arg [Object] row selector accepted by `self[arg, nil]`
    #     (Integer, Range, boolean CArray, ...).
    #   @return [CArray] new table copy.
    def rows (arg)
      table = self[arg, nil].copy
      table.extend(CArray::TableMethods)
      table.column_names = @column_names
      return table
    end

    # @overload select { |table| ... }
    #   Yields `self` and returns a new table restricted to the rows
    #   selected by the block's return value. The block may return
    #   an Integer index array or a boolean mask (which is converted
    #   via `#where`).
    #   @yieldparam table [CArray] `self`.
    #   @yieldreturn [CArray] row selector.
    #   @return [CArray] filtered table copy.
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


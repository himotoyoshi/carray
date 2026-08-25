# CAFrame row sort (memo §5, spine = addressing + gather).
#
# Two entry points, both delegating to the multi-key CArray.sort_addr -- the
# class-method lexicographic sort that returns flat row addresses (distinct from
# the single-key instance CArray#sort_index) -- and gathering every column and
# the index by that address into a view-frame in key order:
#
#   sort_by_key(*keys, order:, masked_position:)  -- sort by named columns, with
#                           per-key or blanket ascending/descending.
#   sort_by { |f| ... }  -- sort by key CArrays the block builds (the escape,
#                           §4.3): derived or composite keys are ordinary column
#                           math.
#
# sort_addr is ascending, so a descending key is expressed by replacing it with
# its dense descending rank (CArray#order(descending: true, method: :dense)):
# this works for every dtype (unlike negation, which cannot reverse a string and
# silently wraps an unsigned integer), and the *dense* rank keeps equal values
# on one rank so ties fall through to later keys in a multi-key sort.
# masked_position (CArray.sort_addr's kwarg) places masked key rows first or
# last (default last).

class CAFrame
  # Sort rows by one or more key columns, lexicographic (the first key is
  # primary), returning a view-frame. Delegates to +CArray.sort_addr+ for the
  # row permutation and gathers every column and the index by it.
  #
  # Each key is a **column name** (or the index axis name), or a
  # **`[name, :asc | :desc]`** pair for a per-key direction. The +order:+ keyword
  # is the direction for bare-name keys (default +:asc+). +masked_position:+
  # sends masked key rows to the +:last+ (default) or +:first+ end.
  #
  #   df.sort_by_key("temp")                              # one column, ascending
  #   df.sort_by_key("station", "temp")                   # lexicographic
  #   df.sort_by_key("temp", order: :desc)                # all keys descending
  #   df.sort_by_key(["station", :asc], ["temp", :desc])  # per-key direction
  #   df.sort_by_key("temp", masked_position: :first)     # masked rows first
  #   df.sort_by_key("time")                              # by the index
  def sort_by_key(*specs, order: :asc, masked_position: :last)
    raise ArgumentError, "sort_by_key requires at least one key" if specs.empty?
    validate_sort_order(order)
    keys = specs.map do |spec|
      name, dir = parse_sort_key_spec(spec, order)
      col = sort_key_column(name)
      dir == :desc ? col.order(descending: true, method: :dense) : col
    end
    select_rows(CArray.sort_addr(*keys, masked_position: masked_position))
  end

  # Sort rows by key columns the block builds (memo §4.3 escape). The block
  # receives the frame and returns a key CArray, or an Array of them for a
  # multi-key lexicographic sort; rows are sorted ascending by +CArray.sort_addr+
  # over those keys and gathered into a view-frame. This is the sort sibling of
  # +filter+: where +sort_by_key+ takes plain column names, the block form lets
  # you build any key with CArray ops -- a descending key is its dense
  # descending rank, derived or composite keys are ordinary column math.
  # +masked_position:+ places masked key rows first or last (default last).
  #
  #   df.sort_by { |f| (f["temp"] - target).abs }   # nearest-to-target first
  #   df.sort_by { |f| f["temp"].order(descending: true, method: :dense) }
  def sort_by(masked_position: :last)
    raise ArgumentError, "sort_by requires a block" unless block_given?
    keys = yield(self)
    keys = [keys] unless keys.is_a?(Array)
    raise ArgumentError, "sort_by block must return a key CArray or an Array of them" if keys.empty?
    keys.each_with_index do |k, i|
      unless k.is_a?(CArray)
        raise ArgumentError, "sort_by key #{i} must be a CArray (got #{k.class})"
      end
      unless k.ndim == 1 && k.shape[0] == nrow
        raise ArgumentError,
              "sort_by key #{i} must be a 1-D column of length #{nrow} (got shape #{k.shape.inspect})"
      end
    end
    select_rows(CArray.sort_addr(*keys, masked_position: masked_position))
  end

  private def parse_sort_key_spec(spec, default_order)
    case spec
    when String, Symbol
      [spec, default_order]
    when Array
      unless spec.size == 2 && (spec[0].is_a?(String) || spec[0].is_a?(Symbol))
        raise ArgumentError, "sort key must be a name or [name, :asc|:desc], got #{spec.inspect}"
      end
      validate_sort_order(spec[1])
      spec
    else
      raise ArgumentError, "sort key must be a name or [name, :asc|:desc], got #{spec.class}"
    end
  end

  private def validate_sort_order(dir)
    return if dir == :asc || dir == :desc
    raise ArgumentError, "sort order must be :asc or :desc, got #{dir.inspect}"
  end

  private def sort_key_column(name)
    key = name.to_s
    col = if @columns.key?(key)
            @columns[key]
          elsif @index && @axis_name == key
            @index
          else
            raise KeyError, "no column #{key.inspect}"
          end
    unless col.ndim == 1
      raise ArgumentError,
            "sort_by_key: key column #{key.inspect} is #{col.ndim}-D; " \
            "sort by a scalar (1-D) column"
    end
    col
  end
end

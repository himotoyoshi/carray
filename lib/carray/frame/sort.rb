# CAFrame row sort (memo §5, spine = addressing + gather).
#
# Two entry points, both delegating to the multi-key CArray.sort_addr -- the
# class-method lexicographic sort that returns flat row addresses (distinct from
# the single-key instance CArray#sort_index) -- and gathering every column and
# the index by that address into a view-frame in key order:
#
#   sort_by_key(*keys, descending:, masked_position:)  -- sort by named columns, with
#                           per-key or blanket ascending/descending.
#   sort_by { |f| ... }  -- sort by key CArrays the block builds (the escape,
#                           §4.3): derived or composite keys are ordinary column
#                           math.
#
# sort_addr is ascending, so a descending key is expressed by replacing it with
# its dense descending rank (CArray#order(descending: true, method: :dense)):
# this works for every data type (unlike negation, which cannot reverse a string and
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
  # **`[name, :asc | :desc]`** pair for a per-key direction. +descending: true+
  # sorts the bare-name keys from largest to smallest (default ascending), as
  # +CArray#order+ takes it. +masked_position:+
  # sends masked key rows to the +:last+ (default) or +:first+ end.
  #
  #   df.sort_by_key("temp")                              # one column, ascending
  #   df.sort_by_key("station", "temp")                   # lexicographic
  #   df.sort_by_key("temp", descending: true)            # all keys descending
  #   df.sort_by_key(["station", :asc], ["temp", :desc])  # per-key direction
  #   df.sort_by_key("temp", masked_position: :first)     # masked rows first
  #   df.sort_by_key("time")                              # by the index
  def sort_by_key(*specs, descending: false, masked_position: :last)
    raise ArgumentError, "sort_by_key requires at least one key" if specs.empty?
    order = descending ? :desc : :asc
    named = specs.map do |spec|
      name, dir = parse_sort_key_spec(spec, order)
      [column_key(name, "sort_by_key"), key_column(column_key(name, "sort_by_key"), "sort_by_key"), dir]
    end
    CAFrame.__send__(:refuse_repeated_names, named.map(&:first), "sort_by_key")
    keys = named.map do |name, col, dir|
      dir == :desc ? col.order(descending: true, method: :dense) : col
    end
    select_rows(CArray.sort_addr(*keys, masked_position: masked_position))
  rescue ArgumentError, CArray::DataTypeError => e
    raise unless named
    name, col, = named.find { |_, c, _| !sortable_key?(c) }
    raise unless name
    reason = e.message.sub(/\A\w+: /, "")
    if col.face?
      # The core names the conversion as an array method; in a frame it is
      # written with sort_by.
      reason = "#{reason.split(";").first}; sort by its values with " \
               "sort_by { |f| f[#{name.inspect}].to_type(:object) }"
      if (storage = col.__send__(:face_storage_method))
        reason += ", or by its storage with " \
                  "sort_by { |f| f[#{name.inspect}].#{storage} }"
      end
    end
    raise e.class, "sort_by_key: the column #{name.inspect} cannot be sorted: #{reason}"
  end

  # Whether +col+ can be a sort key, asked of an empty slice of it so that
  # nothing is sorted: used only to name the column a refusal was about.
  private def sortable_key?(col)
    CArray.sort_addr(col[0...0])
    true
  rescue ArgumentError, CArray::DataTypeError
    false
  end

  # The +n+ rows with the largest values of the key columns, largest first,
  # as a view-frame: +sort_by_key(*keys, descending: true).head(n)+. Several
  # keys break ties in turn, as +sort_by_key+ takes them; rows that tie on
  # every key keep their order. A NaN and a masked key lose to every value,
  # as +CArray#nlargest+ has them, so they come only when fewer than +n+
  # rows have a value.
  #
  #   df.nlargest(3, "revenue")
  #   df.nsmallest(2, "rank", "time")
  #
  # @param n [Integer] how many rows, 0 or more.
  # @param keys [Array<String>] the key columns (or the index axis name).
  # @return [CAFrame]
  # @raise [ArgumentError] when +n+ is negative or no key is given.
  def nlargest (n, *keys)
    return largest_or_smallest("nlargest", n, keys, true)
  end

  # The +n+ rows with the smallest values of the key columns, smallest first,
  # as +nlargest+ gives the largest.
  #
  # @param n [Integer] how many rows, 0 or more.
  # @param keys [Array<String>] the key columns (or the index axis name).
  # @return [CAFrame]
  # @raise [ArgumentError] when +n+ is negative or no key is given.
  def nsmallest (n, *keys)
    return largest_or_smallest("nsmallest", n, keys, false)
  end

  private def largest_or_smallest (verb, n, keys, descending)
    unless n.is_a?(Integer)
      raise TypeError, "#{verb}: the count is an Integer (got #{n.inspect})"
    end
    raise ArgumentError, "#{verb}: the count must be 0 or more (got #{n})" if n < 0
    raise ArgumentError, "#{verb}: give at least one key column" if keys.empty?
    keys.each { |k| column_key(k, verb) }
    return sort_by_key(*keys, descending: descending).head(n)
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

end

# ----------------------------------------------------------------------------
#
#  carray/record_order.rb
#
#  The order of a CARecord: the members its struct names in `order_by:`,
#  compared in that order.
#
#  A record's storage is its bytes, and comparing bytes is no order of the
#  values in them (a little-endian float, a signed integer).  So the
#  ordering members do not run on the storage: they run on one int64 array,
#  each record's rank among the others by the declared members, and the
#  values they return are gathered from the record array by the positions
#  that array gives.  A struct that declares no order has none, and these
#  raise.
#
# ----------------------------------------------------------------------------

class CARecord

  # @overload sort(axis: nil, kind: :quick, masked_position: :last)
  #   Returns a sorted {CARecord} view, ordered by the struct's
  #   `order_by:` members.  With no `axis:` the array is flattened first.
  #   @return [CARecord]
  #   @raise [ArgumentError] when the struct declares no `order_by:`.
  def sort (*args, **kw)
    addr = record_rank.sort_addr(*args, **kw)
    kw[:axis].nil? ? self[addr.flatten] : self[addr]
  end

  # @overload sort_copy(axis: nil, kind: :quick, masked_position: :last)
  #   @return [CARecord] an owned sorted copy.
  def sort_copy (*args, **kw)
    sort(*args, **kw).copy
  end

  # @!method sort_addr(axis: nil, kind: :quick, masked_position: :last)
  #   @return [CArray] the view-flat addresses of a sort by the declared order.
  # @!method sort_index(axis: nil, kind: :quick, masked_position: :last)
  #   @return [CArray] the per-fiber indices of a sort by the declared order.
  # @!method rank_index(axis: nil)
  #   @return [CArray] each record's rank by the declared order.
  # @!method order(axis: nil, descending: false, method: :ordinal, kind: :quick)
  #   @return [CArray] each record's rank by the declared order.
  # @!method min_index(axis: nil)
  #   @return [Integer, CArray] where the smallest record sits.
  # @!method max_index(axis: nil)
  #   @return [Integer, CArray] where the largest record sits.
  # @!method partition_index(kth, axis: nil)
  #   @return [CArray] the indices that partition about the `kth` record.
  [:sort_addr, :sort_index, :rank_index, :order,
   :min_index, :max_index, :partition_index].each do |op|
    define_method(op) { |*args, **kw| record_rank.public_send(op, *args, **kw) }
  end

  # @overload min(axis: nil, keep_axis: false)
  #   Returns the smallest record by the declared order, skipping masked
  #   records; UNDEF when every record is masked.  With `axis:` a
  #   {CARecord} of the smallest along that axis.
  #   @return [CAStruct, CARecord]
  def min (axis: nil, keep_axis: false)
    record_extreme(:min_index, axis, keep_axis)
  end

  # @overload max(axis: nil, keep_axis: false)
  #   The largest record; see {#min}.
  #   @return [CAStruct, CARecord]
  def max (axis: nil, keep_axis: false)
    record_extreme(:max_index, axis, keep_axis)
  end

  # @overload minmax(axis: nil, keep_axis: false)
  #   @return [Array] `[min, max]`.
  def minmax (axis: nil, keep_axis: false)
    [min(axis: axis, keep_axis: keep_axis), max(axis: axis, keep_axis: keep_axis)]
  end

  # @overload partition_copy(kth, axis: nil)
  #   @return [CARecord] partitioned about the `kth` record in the declared
  #     order.  With no `axis:` the array is flattened first.
  def partition_copy (kth, axis: nil)
    if axis.nil?
      flat = flatten
      return flat[flat.send(:record_rank).partition_index(kth)].copy
    end
    take_along_axis(record_rank.partition_index(kth, axis: axis), axis: axis).copy
  end

  # @!method lt(other)
  #   Compares by the declared order.  `other` is a record of the same
  #   struct, or a {CARecord} of them.
  #   @return [CArray] boolean.
  # @!method le(other)
  # @!method gt(other)
  # @!method ge(other)
  [:lt, :le, :gt, :ge].each do |op|
    define_method(op) do |other|
      mine, theirs = record_rank_with(other)
      mine.public_send(op, theirs)
    end
  end

  alias <  lt
  alias <= le
  alias >  gt
  alias >= ge

  private

  # The struct's order_by: members, or a refusal naming where to declare it.
  def record_order_by
    data_class.order_by or
      raise ArgumentError,
            "#{data_class.inspect} declares no order; pass order_by: to " \
            "CArray.struct to name the members records are ordered by"
  end

  # Each record's dense rank by the declared members, shaped like self.
  # Each member is ranked on its own (a numeric member by value, NaN last;
  # a fixlen member by its bytes), and the ranks are folded in member order.
  # Ranking again after each fold keeps every value below the record count.
  def record_rank
    record_rank_of(self).reshape(*shape)
  end

  def record_rank_of (records)
    rank = nil
    record_order_by.each do |key|
      r = records[key].flatten.order(method: :dense)
      if rank.nil?
        rank = r
      else
        top  = r.max
        span = top.equal?(UNDEF) ? 1 : top + 1
        rank = (rank * span + r).order(method: :dense)
      end
    end
    rank
  end

  # Ranks of self and `other` in one ordering, so they can be compared.
  def record_rank_with (other)
    case other
    when CARecord
      unless other.data_class.equal?(data_class)
        raise ArgumentError,
              "can not compare a record of #{data_class.inspect} " \
              "with one of #{other.data_class.inspect}"
      end
      theirs = other.flatten
    when data_class
      theirs = CARecord.new(data_class, 1)
      theirs[0] = other
    else
      raise ArgumentError,
            "can not compare a record of #{data_class.inspect} with #{other.class}"
    end
    n    = elements
    both = record_rank_of(CArray.concatenate([flatten, theirs]))
    mine = both[0...n].reshape(*shape)
    rest = both[n..-1]
    [mine, other.is_a?(CARecord) ? rest.reshape(*other.shape) : rest[0]]
  end

  # The record at each min_index / max_index, gathered from self.
  def record_extreme (index_op, axis, keep_axis)
    rank = record_rank
    if axis.nil?
      i = rank.flatten.public_send(index_op)
      return i.equal?(UNDEF) ? UNDEF : flatten[i]
    end
    unless axis.is_a?(Integer)
      raise ArgumentError, "#{index_op.to_s.sub('_index', '')}: axis must be one Integer for a CARecord"
    end
    axis += ndim if axis < 0
    idx   = rank.public_send(index_op, axis: axis)
    empty = idx.is_masked
    picked_shape = shape.dup
    picked_shape[axis] = 1
    out = take_along_axis(idx.strip_mask(0).reshape(*picked_shape), axis: axis).copy
    if empty.any
      out[empty.reshape(*picked_shape)] = UNDEF
    end
    return out if keep_axis
    out.reshape(*(shape[0...axis] + shape[axis + 1..-1]))
  end

end

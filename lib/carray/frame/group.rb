# CAFrame group_by (memo §5 spine, §11.6 surface).
#
# Grouping is always on the row axis (axis 0). The key is any length-N
# thing: a column name, several column names (composite key), or an
# external length-N CArray. Everything routes through categorize -> codes
# -> group_by_category, so the frame layer only builds the key and hands
# the group iterator back (exposure, §4.3).

class CAFrame
  # Group rows by one or more keys. Each key is a column name (String) or an
  # external length-N CArray. Returns a GroupedFrame.
  def group_by(*keys)
    raise ArgumentError, "group_by needs at least one key" if keys.empty?
    cat  = grouping_categorical(keys)
    axis = keys.size == 1 && keys.first.is_a?(String) ? keys.first : "group"
    GroupedFrame.new(self, cat, axis)
  end

  # Number of rows currently selected — used by group per-group view-frames
  # and elsewhere; already provided by the core (attr_reader :nrow).

  private def grouping_categorical(keys)
    cols = keys.map { |k| key_column(k) }
    if cols.size == 1
      cols.first.categorize
    else
      # Composite key: one object cell per row holding the tuple of key
      # values, categorized by content (the codes are composed from the
      # per-column keys).
      n = nrow
      CArray.object(n) { |i| cols.map { |c| c[i] } }.categorize
    end
  end

  private def key_column(key)
    case key
    when String
      self[key]
    when CArray
      unless key.shape[0] == nrow
        raise ArgumentError,
              "external group key length #{key.shape[0]} != nrow #{nrow}"
      end
      key
    else
      raise ArgumentError, "group key must be a column name or CArray (got #{key.class})"
    end
  end
end

# GroupedFrame — the result of +CAFrame#group_by+ (memo §11.6, §16).
#
# Holds the grouping categorical once (grouping is per-key, computed once
# and shared across every column). Three surfaces:
#   grp["col"]   -> the CArray group iterator (raw exposure)
#   aggregate    -> declarative per-column reductions into a new frame
#   table { |g| }-> cross-column Ruby escape, g is a per-group view-frame
class GroupedFrame
  def initialize(frame, cat, axis_name)
    @frame     = frame
    @cat       = cat
    @axis_name = axis_name
    @labels    = cat.labels          # group values, in code order
  end

  # Number of groups.
  def ngroup
    @labels.size
  end

  # Group key values (one per group), as an Array.
  def labels
    @labels.dup
  end

  # Raw exposure: the CArray group iterator for one column (memo §11.6).
  def [](name)
    @frame[name].group_by_category(@cat)
  end

  # Declarative aggregation (memo §11.6). Spec maps an output column name to
  # +[input_column, reduction]+, where reduction is a Symbol (vectorized,
  # applied through the group iterator) or a Proc (per-group custom, called
  # with the group's column slice).
  def aggregate(spec)
    cols = {}
    spec.each do |out_name, (in_name, reduction)|
      out = out_name.to_s
      cols[out] =
        case reduction
        when Symbol
          self[in_name].public_send(reduction)
        when Proc
          per_group_column(in_name, reduction)
        else
          raise ArgumentError,
                "reduction must be a Symbol or Proc (got #{reduction.class})"
        end
    end
    CAFrame.new(cols, axis_name: @axis_name, index: label_index)
  end

  # Cross-column Ruby escape (memo §11.6). The block receives a per-group
  # view-frame and returns a Hash of output-name => value; the values are
  # collected column-wise across groups into a new frame.
  def table
    collected = {}
    order = nil
    each_group_frame do |g|
      out = yield(g)
      unless out.is_a?(Hash)
        raise ArgumentError, "table block must return a Hash (got #{out.class})"
      end
      order ||= out.keys.map(&:to_s)
      out.each { |k, v| (collected[k.to_s] ||= []) << v }
    end
    cols = {}
    (order || []).each do |name|
      vals = collected[name]
      cols[name] = CArray.object(vals.size) { |i| vals[i] }
    end
    CAFrame.new(cols, axis_name: @axis_name, index: label_index)
  end

  # Convenience reductions over every numeric scalar column (memo §6-4
  # "grp.mean"). Non-numeric / N-D columns are skipped.
  [:sum, :mean, :min, :max].each do |red|
    define_method(red) { reduce_numeric(red) }
  end

  # @return [String]
  def inspect
    "#<GroupedFrame ngroup=#{ngroup} by=#{@axis_name.inspect}>"
  end

  private def label_index
    CArray.object(@labels.size) { |i| @labels[i] }
  end

  NON_NUMERIC = [:object, :boolean, :fixlen].freeze
  private_constant :NON_NUMERIC

  private def reduce_numeric(reduction)
    cols = {}
    @frame.variable_names.each do |name|
      col = @frame[name]
      next unless col.ndim == 1 && !NON_NUMERIC.include?(col.data_type)
      cols[name] = col.group_by_category(@cat).public_send(reduction)
    end
    CAFrame.new(cols, axis_name: @axis_name, index: label_index)
  end

  private def per_group_column(in_name, proc)
    results = []
    each_group_slice(in_name) { |slice| results << proc.call(slice) }
    CArray.object(results.size) { |i| results[i] }
  end

  private def each_group_slice(in_name)
    col = @frame[in_name]
    ngroup.times do |k|
      yield col[group_address(k), *([nil] * (col.ndim - 1))]
    end
  end

  private def each_group_frame
    ngroup.times { |k| yield @frame[group_address(k)] }
  end

  private def group_address(k)
    start = group_offsets[k]
    group_perm[start...(start + group_sizes[k])]
  end

  private def group_perm
    @group_perm ||= @cat.sort_addr
  end

  private def group_offsets
    @group_offsets ||= @cat.reduceat_index
  end

  private def group_sizes
    @group_sizes ||= @cat.category_sizes
  end
end

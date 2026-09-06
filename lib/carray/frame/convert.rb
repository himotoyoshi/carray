# CAFrame row iteration and matrix conversion (memo §11.9, §11.11).

class CAFrame
  # Iterate rows as Ruby Hashes (memo §11.11). This is an escape path — the
  # primary idiom is column-vectorized work (§4.3); each_row is for touching
  # heterogeneous / Face-carrying rows now and then, not hot loops. Without a
  # block, returns an Enumerator.
  def each_row
    return enum_for(:each_row) unless block_given?
    nrow.times { |i| yield row(i) }
    self
  end

  # Export rows as an Array of plain Ruby Hashes (memo §11.11) — the inverse of
  # +from_records+ and the shape +JSON.generate+ wants. Each row is one Hash of
  # column name => value; a scalar cell is a Ruby value, an N-D cell is a Ruby
  # Array, and a masked cell (UNDEF) is +nil+. Normalizing UNDEF -> nil and
  # CArray -> Array (unlike +each_row+, which yields the raw view with UNDEF /
  # CArray slices) is what makes it round-trip: +from_records(df.to_records)+
  # rebuilds the same typing, and the result is JSON-serializable.
  def to_records
    each_row.map { |row| row.transform_values { |v| record_value(v) } }
  end

  # Hand the frame over as a CArray with the minimum work (memo §11.9): a
  # 2-D **view** of shape (nrow, nvar), one column per variable in column
  # order (§12-C). Nothing is materialised — the result is a +CAStack+ over
  # the stored columns, so reads gather from them and writes flow back
  # (§3.6). Call +copy+ on it for an independent, owned matrix; +CArray.tabulate+
  # is the eager sibling that builds one directly.
  #
  # Only same-shape scalar (1-D) columns qualify. An N-D column has no single
  # matrix form and raises — escape it per column with +df["name"]+. A mixed
  # data type set is promoted to a common type (+result_type+, §12-F) through
  # lazy cast lanes, so the promotion costs no buffer either.
  #
  # +writable: true+ demands a result whose writes reach this frame's own
  # columns (the 3.0 +to_ca+ contract). That holds only when every column
  # enters the stack unchanged, so it is refused when a column is read-only
  # or when the common type promotes it: the promoted column is stacked
  # through a cast lane, and a write there is no longer the value the caller
  # handed over. Cast the frame first (+df.cast+) when the promoted matrix is
  # what should be written to.
  def to_ca(writable: false)
    cols = @columns.values
    raise ArgumentError, "frame has no columns to stack into a matrix" if cols.empty?
    nd = @columns.find { |_, c| c.ndim != 1 }
    if nd
      raise ArgumentError,
            "to_ca needs all-scalar (1-D) columns; #{nd.first.inspect} is " \
            "#{nd.last.ndim}-D — escape per column with df[name]"
    end
    refuse_unshared_columns(cols) if writable
    begin
      CArray.stack(cols, axis: 1)
    rescue ArgumentError, RuntimeError => e
      # The columns have no common type (a text or Face column beside a
      # numeric one). Point at the frame-level verb that gives them one.
      raise e.class,
            "#{e.message} -- df.promote(:object) brings every column to its " \
            "surface values, and that frame stacks"
    end
  end

  # The +writable: true+ half of +to_ca+: raise unless the stack's parents are
  # the stored columns themselves. +promote_list+ hands back each column
  # untouched when no coercion is needed, so identity is the exact test for
  # "this column is shared, not re-expressed".
  private def refuse_unshared_columns(cols)
    ro = @columns.find { |_, c| c.read_only? }
    if ro
      raise "CAFrame#to_ca cannot satisfy `writable: true': column " \
            "#{ro.first.inspect} is read-only"
    end
    promoted = CArray.promote_list(cols)
    recast = @columns.keys.zip(cols, promoted).find { |_, col, p| !p.equal?(col) }
    if recast
      raise "CAFrame#to_ca cannot satisfy `writable: true': column " \
            "#{recast[0].inspect} (#{recast[1].data_type}) is promoted to " \
            "#{recast[2].data_type} for the common type, so it is stacked " \
            "through a cast lane; cast the frame first (df.cast) or take the " \
            "column with df[name]"
    end
  end

  private def record_value(v)
    if UNDEF.equal?(v)
      nil
    elsif v.is_a?(CArray)
      v.to_a.map { |e| UNDEF.equal?(e) ? nil : e }
    else
      v
    end
  end
end

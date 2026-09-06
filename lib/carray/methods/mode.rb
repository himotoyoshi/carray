class CArray

  # @overload is_mode(axis: nil)
  #   Returns a shape-preserving boolean CArray, true at every cell
  #   that holds a modal value — a value whose occurrence count equals
  #   the maximum count. This is the first-class primitive of the mode
  #   family: rather than returning the mode *value* (whose count is
  #   data-dependent when there are ties), it marks every occurrence of
  #   every most-frequent value, so ties are never silently broken.
  #
  #   ```
  #   CA_INT32([1, 1, 2, 2, 3]).is_mode  # => [1, 1, 1, 1, 0]  (1 and 2 tie)
  #   ```
  #
  #   With `axis: nil` the frequency is over the whole array; with
  #   `axis: k` it is per fiber along axis `k`, independently. The
  #   result is always the input shape, so — unlike returning the mode
  #   value — the per-axis form has no ragged-length problem. Select the
  #   modal cells with `a[a.is_mode]` / `a[a.is_mode(axis: k)]` (the
  #   {#mask_duplicates} idiom); reduce further with `.min` / `.unique`.
  #
  #   Mode is only meaningful for discrete or binned data: raw float is
  #   almost all unique, so `is_mode` would mark just the single lowest
  #   cell (count 1). Bin first (`bin` / `histogram` / `categorize`).
  #
  #   Masked cells do not participate and are marked false. An empty or
  #   all-masked fiber marks every cell false (mode has no identity; it
  #   never raises). Numeric distinctness follows the discovery family
  #   (all NaN collapse to one value, -0.0 == +0.0); `CA_OBJECT` /
  #   `CA_FIXLEN` follow Ruby `eql?` / `hash`.
  #
  #   @param axis [Integer, nil] axis to take the mode along; `nil` uses
  #     the whole array.
  #   @return [CArray] boolean CArray of `self.shape`.
  def is_mode (axis: nil)
    # Per-fiber two-pass frequency table (C __is_mode__), one lane per data type
    # family (numeric widen / NaN collapse, object rb_hash + rb_eql, fixlen
    # byte-hash + memcmp). Ties are all marked; masked cells stay false.
    if axis.nil?
      flatten.send(:__is_mode__, 0).reshape(*shape)
    else
      __is_mode__(normalize_axis(axis, "is_mode"))
    end
  end

  # @overload mode(axis: nil)
  #   Returns the distinct modal values — the most frequent value(s),
  #   ascending. All values that tie for the highest count are returned
  #   (matching pandas `Series.mode`), because {#is_mode} does not break
  #   ties; `mode` is the value-form consumer of that primitive, read
  #   straight from the frequency table.
  #
  #   With `axis: nil` the result is a 1-D CArray of the distinct modal
  #   values over the whole array (empty when all-masked).
  #
  #   With `axis: k` the per-fiber mode counts are ragged, so — like
  #   per-axis `quantile` — the result is an `Array` of reduced CArrays.
  #   Element `j` holds each fiber's `j`-th smallest modal value, masked
  #   where a fiber has fewer than `j + 1` modes; the Array length is the
  #   widest fiber's mode count. So `mode(axis: k)[0]` is the smallest
  #   mode of each fiber (a plain reduced CArray). To get the rectangular
  #   mask-padded form, stack them: `CArray.stack(a.mode(axis: k), axis: k)`.
  #   An all-masked array yields an empty Array.
  #
  #   Only meaningful for discrete / binned data: raw float is almost all
  #   unique, so every value is modal and the per-axis Array grows to the
  #   fiber length. Bin first. Same NaN / mask semantics as {#is_mode}.
  #
  #   @param axis [Integer, nil] axis to take the mode along; `nil` uses
  #     the whole array.
  #   @return [CArray, Array<CArray>] 1-D CArray (flat) or an Array of
  #     reduced CArrays, one per mode rank (per-axis).
  def mode (axis: nil)
    return __mode_flat if axis.nil?
    k = normalize_axis(axis, "mode")

    # Numeric: the C frequency-table kernel emits the ragged Array<CArray>
    # directly (reduced CArrays, self.shape with axis k dropped). A 1-D input
    # reduces to length-1 CArrays, unwrapped to scalars like flat quantile.
    unless data_type == CA_OBJECT || data_type == CA_FIXLEN
      cols = __mode_axis__(k)
      return ndim == 1 ? cols.map { |col| col[0] } : cols
    end

    # Object / fixlen (rare): per-fiber Ruby path, reusing the flat mode as the
    # single source of what counts as a mode. Move axis k to the innermost
    # position and fold the rest to one outer axis, so each row is a fiber.
    perm = (0...ndim).to_a
    perm.delete(k)
    perm << k
    a2    = (ndim == 1) ? self : transpose(*perm).copy   # (outer..., L)
    outer = a2.shape[0...-1]
    m     = outer.empty? ? 1 : outer.inject(:*)
    flat2 = a2.reshape(m, a2.shape[-1])
    lists = Array.new(m) { |r| flat2[r, nil].__send__(:__mode_flat).to_a }

    # K = widest fiber's mode count. Emit K reduced CArrays (like quantile's
    # per-axis Array<CArray>): slot j holds each fiber's j-th smallest mode,
    # masked where a fiber has fewer than j+1 modes. Stack them to get the
    # rectangular mask-padded form: CArray.stack(result, axis: k).
    kk = lists.map(&:size).max || 0
    (0...kk).map do |j|
      # Take the column shape from self rather than building it from data_type:
      # it carries the element width a fixlen array needs, and it keeps a Face
      # (a time array), whose cells then accept the surface values in `lists`.
      col = flat2[nil, 0].copy
      col[] = UNDEF
      m.times { |r| col[r] = lists[r][j] if j < lists[r].size }
      outer.empty? ? col[0] : col.reshape(*outer)
    end
  end

  private

  # Flat mode: the distinct modal values ascending, 1-D CArray of self's data type.
  # The single source of what counts as a mode (per-axis reuses it per fiber).
  # The distinct values with the maximum count, read from the frequency table
  # (value_counts, which covers numeric / object / fixlen), then sorted
  # ascending. value_counts already skips masked cells.
  def __mode_flat
    values, counts = value_counts
    return values if values.elements == 0
    values[counts.eq(counts.max)].sort
  end

end

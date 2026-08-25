class CArray

  # @overload join(sep = nil)
  #   Flat form.  Stringifies and concatenates every element of `self`
  #   (as if `to_a.flatten.join(sep)`).  Returns a String.
  #
  # @overload join(sep = "", axis:, keep_axis: false)
  #   Per-axis form.  Reduces `axis` into strings, one per fiber along
  #   that axis, and returns the result as a CArray with `axis` removed
  #   (or set to 1 when `keep_axis: true`).  Composable — call `join`
  #   again on the result to collapse another axis or fold to a String.
  #
  #   For a 1-D `self`, the axis form fully reduces and returns the
  #   String directly (matching the flat form and the reduction
  #   convention).
  #
  #   @param sep [String] separator between elements along the axis.
  #   @param axis [Integer] axis to reduce (negative allowed).
  #   @param keep_axis [Boolean] keep the reduced axis as length 1.
  #   @return [CArray, String] a CArray of strings, or a String when
  #     `self` is 1-D.
  #
  # @example Flat form
  #   a = CArray.object(3, 3).seq("a", :succ)
  #   a.join            # => "abcdefghi"
  #   a.join(",")       # => "a,b,c,d,e,f,g,h,i"
  #
  # @example Per-axis form
  #   a = CArray.int32(3, 3).seq
  #   a.join(" ", axis: 1)               # → CArray["0 1 2", "3 4 5", "6 7 8"]
  #   a.join(" ", axis: 1).join("\n")    # => "0 1 2\n3 4 5\n6 7 8"
  #
  # @note The 2.x multi-separator form `a.join("\n", ",")` was removed
  #   in 3.0; use the axis form and chain, e.g.
  #   `a.join(",", axis: 1).join("\n")`.
  def join (*argv, axis: nil, keep_axis: false)
    if argv.size > 1
      raise ArgumentError,
            "join accepts at most one positional separator " \
            "(the 2.x multi-separator form was removed in 3.0; " \
            "use axis: for per-axis join and chain)"
    end
    sep = argv.first  # nil or String

    if axis.nil?
      return sep.nil? ? to_a.join : to_a.join(sep)
    end

    ax = Integer(axis)
    ax += ndim if ax < 0
    if ax < 0 || ax >= ndim
      raise ArgumentError,
            "axis #{axis.inspect} out of range for ndim=#{ndim}"
    end

    sep_str = sep || ""

    # Bring `ax` to the innermost position so we can iterate fibers as
    # rows of a 2-D reshape.  transpose returns a view; reshape may
    # materialize on non-contig, which is fine for this formatting op.
    if ax == ndim - 1
      t = self
    else
      order = (0...ndim).to_a
      order << order.delete_at(ax)
      t = transpose(*order)
    end
    inner = t.shape[-1]
    outer_n = t.elements / inner  # 1 when ndim == 1
    flat = t.reshape(outer_n, inner)

    strings = Array.new(outer_n) { |i| flat[i, nil].to_a.join(sep_str) }

    if ndim == 1
      # Full reduction: return the String directly, or a length-1
      # CArray when keep_axis was requested.
      return keep_axis ? CA_OBJECT([strings.first]) : strings.first
    end

    result_shape = shape.dup
    if keep_axis
      result_shape[ax] = 1
    else
      result_shape.delete_at(ax)
    end

    CA_OBJECT(strings).reshape(*result_shape)
  end

end

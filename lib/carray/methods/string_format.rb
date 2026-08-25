#  CArray.format (class) and CArray#format (instance) — element-wise
#  Kernel.format producing a CAString.  The instance form is the explicit
#  numeric->string escape (a numeric array carries no implicit to_string).
#  Single-feature method file (autoloaded on first format call).

class CArray

  # @overload format(fmt, *argv)
  #   Returns a {CAString} of formatted strings.  Each output cell at index
  #   `idx` is `Kernel.format(fmt, *args)` where a CArray argument contributes
  #   its `[*idx]` cell and any non-CArray argument is broadcast as-is.  The
  #   output shape is taken from the first CArray argument; every CArray
  #   argument must share that shape.
  #   @param fmt [String] `Kernel.format` template.
  #   @param argv [Array<CArray, Object>] per-cell CArrays and/or broadcast scalars.
  #   @return [CAString]
  #   @raise [ArgumentError] when no CArray argument is given, or CArray shapes differ.
  def self.format (fmt, *argv)
    cas = argv.select { |a| a.is_a?(CArray) }
    raise ArgumentError, "CArray.format: at least one CArray argument is required" if cas.empty?
    shape = cas.first.shape
    cas.each do |a|
      next if a.shape == shape
      raise ArgumentError,
            "CArray.format: shape mismatch (#{a.shape.inspect} vs #{shape.inspect})"
    end
    out = CArray.object(*shape)
    out.map_with_index! do |_, *idx|
      args = argv.map { |a| a.is_a?(CArray) ? a[*idx] : a }
      # a masked cell in any source array masks the output (UNDEF), rather
      # than feeding UNDEF into Kernel.format.
      args.any? { |v| v.equal?(UNDEF) } ? UNDEF : Kernel.format(fmt, *args)
    end
    CAString.wrap(out)
  end

  # @overload format(fmt, *argv)
  #   Returns a {CAString} formatting each cell of `self` with `fmt`; `self`
  #   is the first `Kernel.format` argument, so `arr.format("%03d")` renders
  #   the cells and `arr.format("%s=%d", other)` interleaves a second array.
  #   This is the explicit stringify path for numeric (and any) arrays — the
  #   `to_*` string conversions are String-Face only.  Equivalent to
  #   `CArray.format(fmt, self, *argv)`.
  #
  #   Defining a public `CArray#format` shadows the private `Kernel#format`
  #   for CArray instances; internal CArray methods therefore use `sprintf` /
  #   `Kernel.format` explicitly (verified: no bare `format(...)` call runs on
  #   a CArray receiver anywhere in the library).
  #   @param fmt [String] `Kernel.format` template.
  #   @param argv [Array<CArray, Object>] additional per-cell CArrays / broadcast scalars.
  #   @return [CAString]
  #   @raise [ArgumentError] when a CArray argument's shape differs from self.
  def format (fmt, *argv)
    CArray.format(fmt, self, *argv)
  end

end

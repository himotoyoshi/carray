# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for CArray#refer, #reshape, #flatten defined in ext/ca_obj_refer.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.
#
# The CARefer class shell lives in yard-stubs/ruby_carray.rb.

class CArray
  # @!group Views

  # Returns a {CARefer} view of `self` — a strided reinterpretation
  # of the parent's memory.  With no arguments the view has the same
  # `data_type`, shape and `bytes` as `self`; the second form
  # accepts a different `data_type` (or a data_class), and optional
  # `bytes:` / `offset:` keywords so the view exposes the parent's
  # bytes as elements of a different width.
  #
  # `bytes:` must divide `parent.bytes` (or vice versa) so element
  # boundaries align.  `offset:` is measured in parent elements.
  # The total byte extent of the view must fit inside `self`.
  #
  # When `data_type` is a data_class, the result is wrapped in a
  # `CARecord` so field projection continues to work.
  #
  # @overload refer
  #   @return [CARefer] a same-shape same-width alias of `self`.
  # @overload refer(data_type, dim = nil, bytes: nil, offset: 0)
  #   @param data_type [Integer, Symbol, Class] target data type or
  #     a data_class.
  #   @param dim [Array<Integer>, nil] target shape; `nil` reuses
  #     `self.shape` (only valid when the byte width is unchanged).
  #   @param bytes [Integer, nil] target byte width per element;
  #     defaults to `self.bytes`.
  #   @param offset [Integer] offset in parent elements.
  #   @return [CARefer, CARecord]
  #   @raise [RuntimeError] when the byte widths do not divide
  #     evenly, when `offset` is negative, or when the requested
  #     view extends past the parent's data.
  #   @raise [RuntimeError] when reinterpreting a CA_OBJECT parent
  #     with a non-object `data_type`.
  def refer(*argv); end

  # Returns a view of `self` with the requested shape.  Element
  # count must match (`-1` or `:~` may stand in for one axis, whose
  # size is inferred); `nil` copies the corresponding axis from
  # `self`.  When the reshape can be expressed as strides over
  # `self`'s deepest non-CAStride ancestor, the result is a
  # {CAStride}; otherwise a {CARefer}.
  #
  # @overload reshape(*newdim)
  #   @param newdim [Array<Integer, nil, Symbol>] target shape.
  #     Integers are axis sizes; `nil` copies from `self` in
  #     position order (mirrored from the end after the placeholder);
  #     `-1` or `:~` marks the auto-infer placeholder (at most one).
  #   @return [CArray] the reshape view.
  #   @raise [ArgumentError] when the number of dims exceeds
  #     `CA_RANK_MAX`.
  #   @raise [RuntimeError] when the product does not equal
  #     `self.elements` (with no placeholder), when the placeholder
  #     cannot be inferred, when more than one placeholder is
  #     given, or when a `nil` has no matching source axis.
  def reshape(*newdim); end

  # Returns a 1-D view of all cells in row-major order — a
  # {CAStride} when the flatten reduces to pure strides over the
  # deepest ancestor, otherwise a {CARefer}.
  #
  # @overload flatten
  #   @return [CArray] the 1-D view.
  def flatten; end

  # @!endgroup
end

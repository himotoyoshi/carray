# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for methods defined in ext/carray_loop.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

class CArray
  # @!group Iteration

  # @overload each
  #   Yields each element of `self` once in row-major (flat address)
  #   order. Returns an Enumerator when no block is given.
  #   @yieldparam elem [Object]
  #   @return [self, Enumerator]
  def each; end

  # @overload each_addr
  #   Yields each flat address `0...elements` once. Returns an
  #   Enumerator when no block is given.
  #   @yieldparam addr [Integer]
  #   @return [self, Enumerator]
  def each_addr; end

  # @overload each_index
  #   Yields each multi-dimensional index of `self` once in row-major
  #   order.  Block receives one Integer per axis (variadic, not a
  #   single Array); use `|*idx|` to collect them.  Returns an
  #   Enumerator when no block is given.
  #   @yieldparam idx [Integer] one Integer per axis.
  #   @return [self, Enumerator]
  def each_index; end

  # @overload each_with_addr
  #   Yields each `(element, flat-address)` pair in row-major order.
  #   Returns an Enumerator when no block is given.
  #   @yieldparam elem [Object]
  #   @yieldparam addr [Integer]
  #   @return [self, Enumerator]
  def each_with_addr; end

  # @overload each_with_index
  #   Yields each element followed by its multi-dimensional index
  #   components in row-major order.  Block signature is
  #   `|elem, i, j, ...|` (one Integer per axis, not a single Array);
  #   use `|elem, *idx|` to collect them.  Returns an Enumerator when
  #   no block is given.
  #   @yieldparam elem [Object]
  #   @yieldparam idx [Integer] one Integer per axis.
  #   @return [self, Enumerator]
  def each_with_index; end

  # @!endgroup

  # @!group Iteration

  # @overload map!
  #   Replaces each element of `self` with the block's return value.
  #   Mutates `self`.
  #   @yieldparam elem [Object]
  #   @yieldreturn [Object] new value for the cell.
  #   @return [self]
  def map!; end

  # @overload map_addr!
  #   Replaces each element of `self` with the block's return value;
  #   the block receives the flat address rather than the current
  #   value. Mutates `self`.
  #   @yieldparam addr [Integer]
  #   @yieldreturn [Object]
  #   @return [self]
  def map_addr!; end

  # @overload map_index!
  #   Replaces each element of `self` with the block's return value;
  #   the block receives the multi-dimensional index components
  #   (`|i, j, ...|`, one Integer per axis; use `|*idx|` to collect
  #   them) rather than the current value.  Mutates `self`.
  #   @yieldparam idx [Integer] one Integer per axis.
  #   @yieldreturn [Object]
  #   @return [self]
  def map_index!; end

  # @overload map_with_addr!
  #   Replaces each element of `self` with the block's return value;
  #   the block receives `(element, flat-address)`. Mutates `self`.
  #   @yieldparam elem [Object]
  #   @yieldparam addr [Integer]
  #   @yieldreturn [Object]
  #   @return [self]
  def map_with_addr!; end

  # @overload map_with_index!
  #   Replaces each element of `self` with the block's return value;
  #   the block receives the element followed by its multi-dim index
  #   components (`|elem, i, j, ...|`; use `|elem, *idx|` to collect
  #   the index).  Mutates `self`.
  #   @yieldparam elem [Object]
  #   @yieldparam idx [Integer] one Integer per axis.
  #   @yieldreturn [Object]
  #   @return [self]
  def map_with_index!; end

  # @overload collect!
  #   Alias of {#map!}.
  def collect!; end

  # @overload collect_addr!
  #   Alias of {#map_addr!}.
  def collect_addr!; end

  # @overload collect_index!
  #   Alias of {#map_index!}.
  def collect_index!; end

  # @overload collect_with_addr!
  #   Alias of {#map_with_addr!}.
  def collect_with_addr!; end

  # @overload collect_with_index!
  #   Alias of {#map_with_index!}.
  def collect_with_index!; end

  # @!endgroup

  class << self
    # @!group Iteration

    # @overload each_index(*shape) { |*idx| ... }
    #   Yields each multi-dimensional index inside the box `0...d`
    #   for each `d` in `shape`, in row-major order. Independent of
    #   any CArray instance.
    #   @param shape [Array<Integer>] one extent per axis.
    #   @yieldparam idx [Array<Integer>] one index per axis.
    #   @return [Object] the block's last return value.
    #   @example
    #     CArray.each_index(3, 2) { |i, j| print "(#{i} #{j}) " }
    #     # (0 0) (0 1) (1 0) (1 1) (2 0) (2 1)
    def each_index(*shape); end

    # @!endgroup
  end
end

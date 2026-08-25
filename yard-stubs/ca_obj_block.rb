# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for CABlock accessors and address helpers defined in
# ext/ca_obj_block.c.  The CABlock class shell lives in
# yard-stubs/ruby_carray.rb.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

class CABlock
  # @!group Block geometry

  # @overload size0
  #   Returns the parent dimension sizes that the block is carved
  #   from (one Integer per axis).  Distinct from `shape`, which is
  #   the block's own shape (= `count` after step / stride logic).
  #   @return [Array<Integer>]
  def size0; end

  # @overload start
  #   Returns the starting index of the block within the parent, per
  #   axis.
  #   @return [Array<Integer>]
  def start; end

  # @overload step
  #   Returns the per-axis step (stride in parent index units) the
  #   block walks the parent with.
  #   @return [Array<Integer>]
  def step; end

  # @overload count
  #   Returns the per-axis number of elements the block exposes.
  #   Same as `shape`.
  #   @return [Array<Integer>]
  def count; end

  # @overload offset
  #   Returns the block's base flat offset into the parent (in
  #   element units), set at construction and adjusted as start[]
  #   moves.
  #   @return [Integer]
  def offset; end

  # @!endgroup

  # @!group Address mapping

  # @overload idx2addr0(*idx)
  #   Maps a per-axis view index tuple to the corresponding flat
  #   address into the parent (= "addr0").  Useful for projecting a
  #   view-local coordinate back onto the parent's buffer.
  #   @param idx [Array<Integer>] one Integer per axis;
  #     `idx.length == self.ndim` is required.
  #   @return [Integer]
  #   @raise [ArgumentError] when the number of args does not equal
  #     `self.ndim`.
  #   @raise [IndexError] when any `idx[k]` is out of range for the
  #     block's `shape[k]`.
  def idx2addr0(*idx); end

  # @overload index2addr0(*idx)
  #   Alias of {#idx2addr0}.
  def index2addr0(*idx); end

  # @overload addr2addr0(addr)
  #   Flat-address variant of {#idx2addr0}.  Unravels the block-local
  #   flat `addr` into a multi-dim index, then maps that to the
  #   parent's flat address.
  #   @param addr [Integer] block-local flat address
  #     (`0...self.elements`).
  #   @return [Integer]
  def addr2addr0(addr); end

  # @!endgroup
end

# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for methods defined in ext/carray_core.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

class CArray
  # @!group Attach lifecycle
  #
  # The `attach` / `attach!` family is an internal lifecycle API used
  # by library authors writing CArray-aware C extensions. End users
  # should not normally need to call these methods — view algebra and
  # `CArray#[]` / `[]=` handle attach/sync transparently.
  #
  # The block-form `attach` (no sync on exit) and `attach!` (sync on
  # exit) wrap a body of code so that the underlying memory block is
  # guaranteed to be materialized while the block runs and is
  # released afterward. The dunder forms (`__attach__`, `__sync__`,
  # `__detach__`) expose the raw three-step protocol for callers that
  # cannot use a block.

  # @overload attach { ... }
  #   Attaches `self`, yields, and detaches on block exit. No sync
  #   is performed.
  #   @yield
  #   @return [Object] the block's return value.
  def attach; end

  # @overload attach! { ... }
  #   Attaches `self`, yields, then syncs and detaches on block exit.
  #   Use this form when the block mutates `self.ptr` and you need
  #   the changes flushed back to the parent.
  #   @yield
  #   @return [Object] the block's return value.
  def attach!; end

  # @private
  # @overload __attach__
  #   Raw attach: materializes the memory block of `self` and leaves
  #   it attached. Caller is responsible for the matching
  #   `__detach__` (and `__sync__`, if changes were made).
  #
  #   Prefer the block form {#attach!} unless block scope is
  #   impossible.
  #   @return [self]
  #   @api private
  def __attach__; end

  # @private
  # @overload __sync__
  #   Raw sync: writes any pending changes in `self.ptr` back to the
  #   parent. Requires `self` to be currently attached.
  #   @return [self]
  #   @api private
  def __sync__; end

  # @private
  # @overload __detach__
  #   Raw detach: releases the memory block paired with `__attach__`.
  #   @return [self]
  #   @api private
  def __detach__; end

  # @!endgroup

  # @!group Attributes

  # @overload members
  #   Returns the ordered list of member names for `self.data_class`.
  #   Only valid when `self` carries a `data_class` (e.g. a
  #   `CARecord`).
  #   @return [Array<Symbol>]
  #   @raise [RuntimeError] if `self` has no `data_class`.
  def members; end

  # @overload fields
  #   Returns one field view per member of `self.data_class`, in
  #   declaration order. Each entry is a CArray sharing storage with
  #   `self`.
  #   @return [Array<CArray>]
  #   @raise [RuntimeError] if `self` has no `data_class`.
  def fields; end

  # @overload fields_at(*names)
  #   Returns the field views for the named members of
  #   `self.data_class`, in the given order.
  #   @param names [Array<Symbol, String, Integer>] member names or
  #     positional indices.
  #   @return [Array<CArray>]
  #   @raise [RuntimeError] if `self` has no `data_class`.
  def fields_at(*names); end

  # @!endgroup

  class << self
    # @!group Attach lifecycle

    # @overload attach(*arrays) { ... }
    #   Attaches every CArray in `arrays`, yields, and detaches them
    #   in reverse order on block exit. No sync is performed.
    #   @param arrays [Array<CArray>]
    #   @yield
    #   @return [Object] the block's return value.
    def attach(*arrays); end

    # @overload attach!(*arrays) { ... }
    #   Attaches every CArray in `arrays`, yields, then syncs and
    #   detaches each on block exit.
    #   @param arrays [Array<CArray>]
    #   @yield
    #   @return [Object] the block's return value.
    def attach!(*arrays); end

    # @!endgroup
  end
end

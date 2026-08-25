# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for CAByteSwap and CArray#swap_bytes / #endian defined in
# ext/ca_obj_byte_swap.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

# Byte-order-reversed view of the parent.  Same shape and byte
# width as the parent; each cell exposes the byte-reversed
# interpretation.  For primitive numeric parents `CArray#swap_bytes`
# routes through `CAMonOp` instead, so a CAByteSwap instance is
# usually seen only for `CA_FIXLEN` parents.
#
# Writes through the view flow back to the parent on detach
# (byte-swap is involutive).
class CAByteSwap < CAView
end

class CArray
  # @!group Views

  # Returns a lazy view of `self` whose cells are byte-swapped
  # versions of the parent cells.  Materialises on attach.
  # Primitive numeric parents get a `CAMonOp` view; `CA_FIXLEN`
  # parents (with or without a data_class) get a {CAByteSwap} view.
  #
  # For eager copy semantics use `arr.swap_bytes.to_ca`.  The
  # in-place idiom is `ca[] = ca.swap_bytes`; there is no
  # `swap_bytes!`.
  #
  # @overload swap_bytes
  #   @return [CArray] byte-swapped view of `self`.
  #   @raise [CADataTypeError] when `self.data_type` is `CA_OBJECT`
  #     (object arrays cannot be byte-swapped).
  def swap_bytes; end

  # Returns a view of `self` in the requested byte order.
  #
  # `byte_order` is one of:
  # - `:preserve` / `:native` — identity, since CArrays are stored
  #   host-endian.
  # - `:big` — identity on big-endian hosts, otherwise a byte-swap
  #   view.
  # - `:little` — identity on little-endian hosts, otherwise a
  #   byte-swap view.
  #
  # The keyword set matches `BulkMemoryView.from(producer, endian:)`.
  #
  # @overload endian(byte_order)
  #   @param byte_order [Symbol] one of `:preserve`, `:native`,
  #     `:big`, `:little`.
  #   @return [CArray] `self` or a byte-swap view.
  #   @raise [ArgumentError] when `byte_order` is not one of the
  #     accepted symbols.
  def endian(byte_order); end

  # @!endgroup
end

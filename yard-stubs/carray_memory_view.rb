# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for singleton methods defined in ext/carray_memory_view.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

class CArray
  class << self
    # @!group MemoryView interop

    # @overload memory_view_available?(obj)
    #   Returns `true` if `obj` exposes the Ruby `rb_memory_view`
    #   protocol and a view can be acquired from it. Lightweight probe
    #   used to gate {.from_memory_view} / {.wrap_memory_view} calls.
    #
    #   Returning `true` does not guarantee acquisition will succeed —
    #   a producer may still refuse a particular flag combination at
    #   acquisition time.
    #   @param obj [Object] any object (typically a foreign array such
    #     as `Numo::NArray`, `Arrow::Array`, a `bytearray`, or a
    #     CArray).
    #   @return [Boolean]
    #   @example
    #     CArray.memory_view_available?(CArray.int32(3))      # => true
    #     CArray.memory_view_available?("plain string")        # => false
    def memory_view_available?(obj); end

    # @overload memory_view_reject_reason(obj)
    #   Returns a String explaining why CArray's MemoryView producer
    #   refuses to export `obj`, or `nil` if no problem is detected.
    #
    #   Diagnostic only; useful when {.memory_view_available?} returns
    #   `false` on a CArray and the generic "memory view not available"
    #   error does not say which link in the parent chain caused the
    #   reject. Consumers that need to debug an alias-chain reject
    #   (mask propagation, non-contiguous strided view, etc.) call this
    #   to print a human-readable reason.
    #   @param obj [Object]
    #   @return [String, nil] reason text, or `nil` when acquisition
    #     would succeed.
    def memory_view_reject_reason(obj); end

    # @overload from_memory_view(src, data_type: nil, mask: nil)
    #   Returns a new `CArray` that owns an independent copy of `src`'s
    #   buffer. Accepts both contiguous and strided producers; strided
    #   sources are gathered into a freshly allocated row-major
    #   buffer.
    #
    #   For typeless producers (format `nil`, e.g. byte blobs from
    #   `IO#read`), `data_type:` is required and the byte buffer is
    #   reinterpreted as that data type with `ndim = 1`. For typed
    #   producers `data_type:` is optional; when given it must match
    #   the producer's format.
    #
    #   `mask:` accepts a paired buffer-protocol source whose shape
    #   matches `src` and whose item size is 1 (PEP 3118 `?` / `B` /
    #   `b`). The mask bytes are copied into the canonical
    #   `CA_BOOLEAN` mask slot with non-zero coerced to `1`. The copy
    #   is independent of both buffers after the call.
    #   @param src [Object] any MemoryView producer.
    #   @param data_type [Symbol, Integer, Class, nil] target data
    #     type. Required for typeless producers; optional (must match
    #     producer format) for typed ones.
    #   @param mask [Object, nil] optional paired mask MemoryView
    #     source. Must match `src.shape` and use a 1-byte/element
    #     format.
    #   @return [CArray] independent copy; not a `CAWrap`.
    #   @raise [ArgumentError] if `src` is not a MemoryView producer,
    #     if `data_type:` is missing for a typeless source, if
    #     `data_type:` conflicts with the producer's format, or if
    #     the supplied `mask:` fails shape / dtype / contiguity
    #     validation.
    #   @example Copy from a strided source
    #     a = CArray.int32(4, 3).seq
    #     b = CArray.from_memory_view(a.transpose)
    #     b.shape    # => [3, 4]
    #     b.equal?(a)  # => false
    #   @example Copy paired (data, mask) — independent of source
    #     data = CArray.uint8(3) { |i| i }
    #     mask = CArray.boolean(3) { |i| i.zero? ? 1 : 0 }
    #     c = CArray.from_memory_view(data, mask: mask)
    #     c.has_mask?   # => true
    #     data[0] = 99  # source change does not reach c
    def from_memory_view(src, data_type: nil, mask: nil); end

    # @overload wrap_memory_view(src, data_type: nil, mask: nil)
    #   Returns a `CAWrap` (or `CAStride` for strided producers) that
    #   borrows `src`'s buffer zero-copy. Writes through the wrap
    #   reach the source buffer; external changes to the source are
    #   visible through the wrap.
    #
    #   The borrowed view is kept alive for the lifetime of the
    #   returned object via internal ivars; the source is released
    #   when the wrap is garbage-collected.
    #
    #   Contiguous typed producers return a `CAWrap`. Strided typed
    #   producers return a `CAStride` layered on an inner `CAWrap` of
    #   the producer's first byte, preserving the full stride pattern
    #   (including negative strides where the producer offers them).
    #   Typeless producers (format `nil`) require `data_type:` and are
    #   reinterpreted with `ndim = 1`.
    #
    #   `mask:` accepts a paired buffer-protocol source whose shape
    #   matches `src` and whose item size is 1 (PEP 3118 `?` / `B` /
    #   `b`). The mask buffer is borrowed; writes to either side
    #   propagate, and the mask MemoryView is released when the wrap
    #   is collected. In this release, `mask:` requires a row-major
    #   contiguous data source and a row-major contiguous mask
    #   buffer.
    #
    #   The receiver picks the class of the result. Called on `CArray`
    #   it builds a `CAWrap`; called on a subclass of `CAWrap` it
    #   builds that subclass, so a gem bridging a foreign buffer can
    #   name where the array came from without writing a C extension.
    #   Any other receiver raises `TypeError`, and a strided producer
    #   raises `ArgumentError` when a subclass was asked for, since the
    #   result would be a `CAStride` rather than the named class.
    #
    #   The class marks the provenance of the returned object only. A
    #   view derived from it is a `CABlock` or a `CAStride` like any
    #   other — a slice of a borrowed image is no longer that image —
    #   so do not build an API that expects the class to survive view
    #   algebra. For semantic identity that does survive it, see
    #   {file:docs/topics/CAFace.md CAFace}.
    #   @param src [Object] any MemoryView producer.
    #   @param data_type [Symbol, Integer, Class, nil] target data
    #     type, same rules as {.from_memory_view}.
    #   @param mask [Object, nil] optional paired mask MemoryView
    #     source.
    #   @return [CAWrap, CAStride] zero-copy borrowed view of `src`.
    #     A `CAStride` is returned when `src` is strided (and `mask:`
    #     is not given); otherwise a `CAWrap`, or the subclass of
    #     `CAWrap` the method was called on.
    #   @raise [TypeError] if the receiver is neither `CArray` nor a
    #     subclass of `CAWrap`.
    #   @raise [ArgumentError] if `src` is not a MemoryView producer,
    #     if `data_type:` is missing for a typeless source, if
    #     `data_type:` conflicts with the producer's format, or if
    #     the supplied `mask:` fails validation (shape / ndim /
    #     dtype / item_size / contiguity). Also raises when `mask:`
    #     is combined with a strided data source — that combination
    #     is not supported in this release.
    #   @example Zero-copy write propagation
    #     a = CArray.int32(4).seq
    #     w = CArray.wrap_memory_view(a)
    #     w[0] = 999
    #     a[0]   # => 999
    #   @example Paired masked wrap
    #     data = CArray.uint8(3) { |i| i + 10 }
    #     mask = CArray.boolean(3) { 0 }
    #     w = CArray.wrap_memory_view(data, mask: mask)
    #     w[1] = UNDEF      # writes the source mask buffer
    #     mask[1]           # => 1
    #   @example Naming where a borrowed buffer came from
    #     class VipsPixels < CAWrap
    #       def image ; instance_variable_get(:@vips_image) ; end
    #     end
    #     v = VipsPixels.wrap_memory_view(bmv)
    #     v.class            # => VipsPixels
    #     v[0..1, nil].class # => CABlock  (the class does not descend)
    def wrap_memory_view(src, data_type: nil, mask: nil); end

    # @!endgroup
  end
end

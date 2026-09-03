# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for class hierarchy and constants declared in
# ext/ruby_carray.c. See yard-stubs/README.md and yard-stubs/STYLE.md.

# Multi-dimensional numeric array.
#
# See `docs/Tutorial.md` for a guided tour, the per-topic guides under
# `docs/guides/`, and the method index below for the full reference.
class CArray < Object
  # Library semantic version, e.g. `"3.0.0.dev"`.
  VERSION = ""

  # Sentinel marking "the caller did not give this argument", used by
  # C entry points whose fill value may legitimately be `nil` (so `nil`
  # itself cannot mark absence). Never pass it in.
  # @api private
  UNSPECIFIED = nil

  # `true` when the build links `<complex.h>`; `false` otherwise.
  # Complex array types (`:cmplx64`, `:cmplx128`) require this to be
  # `true`.
  HAVE_COMPLEX = nil

  # Raised when a method is invoked on a CArray whose `data_type` is
  # incompatible with the operation (e.g. binary I/O on `:object`,
  # quickselect on `:fixlen`).
  class DataTypeError < StandardError
  end
end

# Untyped external-memory wrapper. Created via
# {CArray.wrap_memory_view} for zero-copy interop with NumPy / Numo /
# Arrow.
class CAWrap < CArray
end

# Zero-dimensional CArray. One element, broadcasts like a scalar in
# elementwise ops.
class CScalar < CArray
end

# Base class of all virtual (view) CArrays. Has a `parent` and an
# `attach` lifecycle; `entity? == false`.
class CAView < CArray
end

# General strided view. Common base for views expressible as
# `parent.ptr + base_offset + Σ idx[k] * strides[k]`.
class CAStride < CAView
end

# `CArray#reshape` / `CArray#flatten` view. Also used for type or
# byte-size reinterpretation.
class CARefer < CAStride
end

# Rectangular slice / sub-array view (`a[r1, r2, ...]`).
class CABlock < CAStride
end

# Member-of-fixlen view (`a.field(offset, type)`).
class CAField < CAStride
end

# Boolean / fancy-index gather view.
class CASelect < CAView
end

# Per-element Ruby callback bridge view.
class CAObject < CAView
end

# Repeat-broadcast view (`a.repeat(n0, n1, ...)`).
class CARepeat < CAStride
end

# Ragged concatenation view (`CArray.meld(*arrays, axis:)`). Welds
# K parents along one of their existing axes with (potentially) uneven
# segment lengths. Prefix-sum table {#seg_offsets} keeps segment
# boundaries explicit so segment resolution stays per-segment rather
# than per-cell.  Ruby entry: {CArray.meld} / {CArray#meld}
# (`lib/carray/stack.rb`).
#
# See `docs/objects/CAMeld.md` for the user-facing overview.
class CAMeld < CAView
  # Returns the number of parent arrays welded by `self`.
  # @return [Integer]
  def n_parents; end

  # Returns the parent arrays welded by `self`. The Array holds
  # references to the constructor's inputs; identity is preserved.
  # @return [Array<CArray>]
  def parents; end

  # Returns the axis along which the parents are welded (the
  # ragged axis). Non-meld axes have uniform length across parents.
  # @return [Integer] in `[0, ndim)`.
  def meld_axis; end

  # Returns the prefix-sum offsets along {#meld_axis}. Length
  # `n_parents + 1`; `seg_offsets[k]` is the starting position of
  # parent `k` in the view, and `seg_offsets[n_parents]` equals
  # `shape[meld_axis]`.
  # @return [Array<Integer>]
  # @example
  #   a = CArray.int32(3, 4) { 0 }
  #   b = CArray.int32(5, 4) { 0 }
  #   c = CArray.int32(1, 4) { 0 }
  #   CArray.meld(a, b, c, axis: 0).seg_offsets   # => [0, 3, 8, 9]
  def seg_offsets; end
end

# Namespace for CArray utility module functions.
module CA
end

# --- Top-level constants (defined on Object in ext/ruby_carray.c) ---

# Maximum supported `ndim`.
CA_RANK_MAX = nil

# @!group Data type symbols
#
# Each constant is a `Symbol` matching the canonical `data_type`
# name. Aliases share Symbol identity with their canonical form
# (e.g. `CA_DOUBLE == CA_FLOAT64` via Symbol equality).

# `:fixlen` — fixed-length opaque byte blob; element byte size set
# per array.
CA_FIXLEN = :fixlen
# `:boolean` — 8-bit boolean.
CA_BOOLEAN = :boolean
# `:int8` — signed 8-bit integer.
CA_INT8 = :int8
# `:uint8` — unsigned 8-bit integer.
CA_UINT8 = :uint8
# `:int16` — signed 16-bit integer.
CA_INT16 = :int16
# `:uint16` — unsigned 16-bit integer.
CA_UINT16 = :uint16
# `:int32` — signed 32-bit integer.
CA_INT32 = :int32
# `:uint32` — unsigned 32-bit integer.
CA_UINT32 = :uint32
# `:int64` — signed 64-bit integer.
CA_INT64 = :int64
# `:uint64` — unsigned 64-bit integer.
CA_UINT64 = :uint64
# `:float32` — IEEE-754 single-precision float.
CA_FLOAT32 = :float32
# `:float64` — IEEE-754 double-precision float.
CA_FLOAT64 = :float64
# `:cmplx64` — single-precision complex (two `float32` packed).
CA_CMPLX64 = :cmplx64
# `:cmplx128` — double-precision complex.
CA_CMPLX128 = :cmplx128
# `:object` — boxed Ruby object slot.
CA_OBJECT = :object

# Alias of {CA_UINT8}.
CA_BYTE = :uint8
# Alias of {CA_INT16}.
CA_SHORT = :int16
# Alias of {CA_INT32}.
CA_INT = :int32
# Alias of {CA_FLOAT32}.
CA_FLOAT = :float32
# Alias of {CA_FLOAT64}.
CA_DOUBLE = :float64
# Alias of {CA_CMPLX64}.
CA_COMPLEX = :cmplx64
# Alias of {CA_DCOMPLEX}.
CA_DCOMPLEX = :cmplx128
# Platform-native size type alias; resolves to `:int64` on 64-bit
# builds and `:int32` on 32-bit builds.
CA_SIZE = :int64

# @!endgroup

# Byte alignment of each element type, used by `CArray.wrap` and
# MemoryView interop helpers. Internal, not part of the user surface.
CA_ALIGN_VOIDP = nil # :nodoc:
CA_ALIGN_FIXLEN = nil # :nodoc:
CA_ALIGN_BOOLEAN = nil # :nodoc:
CA_ALIGN_INT8 = nil # :nodoc:
CA_ALIGN_INT16 = nil # :nodoc:
CA_ALIGN_INT32 = nil # :nodoc:
CA_ALIGN_INT64 = nil # :nodoc:
CA_ALIGN_FLOAT32 = nil # :nodoc:
CA_ALIGN_FLOAT64 = nil # :nodoc:
CA_ALIGN_CMPLX64 = nil # :nodoc:
CA_ALIGN_CMPLX128 = nil # :nodoc:
CA_ALIGN_OBJECT = nil # :nodoc:

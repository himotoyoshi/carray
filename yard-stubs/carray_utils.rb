# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for methods defined in ext/carray_utils.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

class CArray
  # @!group Index and address conversion

  # @overload normalize_axis(axis, name = nil)
  #   Returns the canonical non-negative integer axis index in
  #   `[0, ndim)` for `self`. Accepts Python-style negative indices
  #   (`-1` ⇒ `ndim-1`).
  #   @param axis [Integer] axis index, possibly negative.
  #   @param name [String, nil] argument name to embed in error
  #     messages (e.g. `"axis"`, `"at"`).
  #   @return [Integer]
  #   @raise [ArgumentError] if `axis` is outside `[-ndim, ndim)`.
  def normalize_axis(axis, name = nil); end

  # @overload normalize_axes(axes, name = nil)
  #   Returns an Array of canonical non-negative axis indices in
  #   input order. Accepts:
  #
  #   - `nil` ⇒ all axes `[0, 1, ..., ndim-1]`
  #   - `Integer` ⇒ `[normalize_axis(axis)]`
  #   - `Array<Integer>` ⇒ each normalized, preserving input order
  #
  #   @param axes [Integer, Array<Integer>, nil]
  #   @param name [String, nil] argument name for error messages.
  #   @return [Array<Integer>]
  #   @raise [ArgumentError] on out-of-range or duplicate axes.
  def normalize_axes(axes, name = nil); end

  # @!endgroup

  class << self
    # @!group Index and address conversion

    # @overload normalize_axis(axis, ndim, name = nil)
    #   Class-method form of {CArray#normalize_axis} that operates on
    #   an explicit `ndim` rather than a CArray instance. Range is
    #   `[0, ndim)`.
    #
    #   For an insertion position (valid range `[0, old_ndim]`
    #   inclusive), pass `old_ndim + 1` as `ndim`. Used by class-level
    #   callers such as `CArray.stack(list, axis:)` that must
    #   normalize before any instance is available, and by
    #   composition helpers in `lib/carray/compose.rb`.
    #   @param axis [Integer]
    #   @param ndim [Integer]
    #   @param name [String, nil]
    #   @return [Integer]
    def normalize_axis(axis, ndim, name = nil); end

    # @!endgroup

    # @!group Type guessing

    # @overload guess_type_and_bytes(type_spec, bytes = nil)
    #   Resolves a user-supplied type spec into the pair
    #   `[data_type_code, bytes]`. `data_type_code` is the internal
    #   `int8_t` numeric code (see {CArray.data_type_code}); `bytes`
    #   is the per-element byte size (`0` for non-`:fixlen`).
    #   @param type_spec [Symbol, Integer, Class, String]
    #   @param bytes [Integer, nil] element byte size, used only for
    #     `:fixlen`.
    #   @return [Array(Integer, Integer)]
    def guess_type_and_bytes(type_spec, bytes = nil); end

    # @!endgroup

    # @!group String scanning (internal)

    # @overload _scan_float(str, fill_value = nil)
    #   Parses `str` as a single double-precision float. Returns
    #   `fill_value` (or `NaN` if `fill_value` is nil) when `str` is
    #   `nil` or unparseable. Internal helper used by text-format I/O
    #   readers; end users should prefer Ruby's `Float()` /
    #   `String#to_f`.
    #   @param str [String, nil]
    #   @param fill_value [Float, nil]
    #   @return [Float]
    #   @api private
    def _scan_float(str, fill_value = nil); end

    # @overload _scan_int(str, fill_value = nil)
    #   Parses `str` as a single integer. Returns `fill_value`
    #   (or `0` if `fill_value` is nil) when `str` is `nil` or
    #   unparseable. Internal helper used by text-format I/O readers.
    #   @param str [String, nil]
    #   @param fill_value [Integer, nil]
    #   @return [Integer]
    #   @api private
    def _scan_int(str, fill_value = nil); end

    # @!endgroup
  end
end

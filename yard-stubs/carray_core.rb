# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for methods defined in ext/carray_core.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

class CArray
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
end

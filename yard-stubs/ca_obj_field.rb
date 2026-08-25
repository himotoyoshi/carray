# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for CArray#field defined in ext/ca_obj_field.c.  The CAField
# class shell lives in yard-stubs/ruby_carray.rb.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

class CArray
  # @!group Views

  # @overload field(offset, data_type, bytes: nil)
  #   Returns a {CAField} view of one field of a fixlen-record `self`.
  #   The view has the same shape as `self`; each element is the
  #   `bytes`-wide slice of element type `data_type` at byte `offset`
  #   within the corresponding record.  No data is copied; writes go
  #   through to `self`.
  #   @param offset [Integer] byte offset of the field within one record.
  #   @param data_type [Symbol, Integer] element type symbol or constant.
  #     `:object` is not allowed.
  #   @param bytes [Integer, nil] element size; required for `:fixlen`,
  #     inferred otherwise.
  #   @return [CAField]
  #   @raise [RuntimeError] when `offset` is negative or the
  #     `offset + bytes` window falls outside one parent record.
  # @overload field(offset, template)
  #   Returns a CARefer over a {CAField}: takes `template.elements *
  #   template.bytes` bytes at `offset` and exposes them with
  #   `template`'s element type and trailing shape.
  #   @param offset [Integer]
  #   @param template [CArray] element type and trailing shape donor.
  #   @return [CArray]
  # @overload field(offset, data_class)
  #   Returns a `CARecord` wrapping a {CAField} so the result carries
  #   `data_class`'s encode/decode dispatch.
  #   @param offset [Integer]
  #   @param data_class [Class] e.g. a CAStruct subclass.
  #   @return [CArray]
  # @overload field(name)
  #   Returns the field named `name`.  Delegates to the parent's Face
  #   layer (`rb_ca_face_field`); resolution depends on the record
  #   schema attached to `self`.
  #   @param name [Symbol, String]
  #   @return [CArray]
  def field(*); end

  # @!endgroup
end

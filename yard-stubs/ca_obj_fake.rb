# DOCUMENTATION ONLY — DO NOT REQUIRE.
# Stubs for methods defined in ext/ca_obj_fake.c.
# See yard-stubs/README.md and yard-stubs/STYLE.md.

# CAFace-family data_type reinterpret view.  Presents its parent with a
# different `data_type` (and, for `:fixlen`, a different `bytes`);
# reads and writes cast on the fly.  Storage is shared with the
# parent.
class CAFake < CAView
end

class CArray
  # @!group Views
  # @overload fake(data_type, bytes: 0)
  #   Returns a {CAFake} view of `self` whose element type is
  #   `data_type` (and `bytes:` for `:fixlen`).  Reads and writes go
  #   through the cast table, so the returned view shares storage
  #   with `self` but exposes it under a different data_type.
  #   A Face refuses: its cells do not mean their storage bytes, so
  #   reading them under another type hands back what the surface exists to
  #   hide. Use {CArray#to_type} for the values, or `face.parent.fake` to
  #   reinterpret the storage on purpose. A Numeric Face, whose surface *is*
  #   its storage, is unaffected.
  #   @param data_type [Symbol, Integer, Class, String]
  #   @param bytes [Integer] element byte size for `:fixlen`.
  #   @return [CAFake]
  #   @raise [TypeError] when `self` is a Face and the request would read its
  #     storage under another type.
  def fake(data_type, bytes: 0); end
  # @!endgroup
end

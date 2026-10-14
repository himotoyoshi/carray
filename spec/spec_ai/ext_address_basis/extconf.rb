require "mkmf"

# Include carray's headers (this fixture uses ca_with_address_bases from
# carray.h, extern in carray_ext.bundle).
$CFLAGS << " -I../../../ext"

# macOS: symbols are resolved at load time from the already-loaded
# carray_ext.bundle in the same Ruby process.  Linux: default shared-library
# symbol visibility handles this.
if RUBY_PLATFORM =~ /darwin/
  $LDFLAGS << " -undefined dynamic_lookup"
end

create_makefile("address_basis_c")

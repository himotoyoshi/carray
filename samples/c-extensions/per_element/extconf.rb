require "mkmf"

# CA_FOR_EACH_ELEMENT macros live in ca_for_each_element.h, alongside
# carray.h.  Symbols are resolved at load time from the already-loaded
# carray_ext.bundle.
$CFLAGS << " -I../../../ext"

if RUBY_PLATFORM =~ /darwin/
  $LDFLAGS << " -undefined dynamic_lookup"
end

create_makefile("per_element")

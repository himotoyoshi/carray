require "mkmf"

# TEST FIXTURE for the cslab author surface (ca_call_cslab_*, declared in
# carray.h).  Mirror of examples/c-extensions/cslab/.  Symbols resolve at
# load time from the already-loaded carray_ext.bundle.
$CFLAGS << " -I../../../ext"

if RUBY_PLATFORM =~ /darwin/
  $LDFLAGS << " -undefined dynamic_lookup"
end

create_makefile("cslab")

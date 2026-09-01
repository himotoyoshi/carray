require "mkmf"

# TEST FIXTURE for the cfunc_r author surface (ca_call_cfunc_*_r, declared
# in carray.h).  Mirror of examples/c-extensions/cfunc_r/.  Symbols resolve
# at load time from the already-loaded carray_ext.bundle.
$CFLAGS << " -I../../../ext"

if RUBY_PLATFORM =~ /darwin/
  $LDFLAGS << " -undefined dynamic_lookup"
end

create_makefile("cfunc_r")

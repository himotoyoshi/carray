require "mkmf"

# TEST FIXTURE for CA_WITH_BUFFER / rb_ca_call_with_buffer (ca_for_buffer.h, alongside
# carray.h).  Mirror of examples/c-extensions/with_buffer/.  Symbols resolve at
# load time from the already-loaded carray_ext.bundle.
$CFLAGS << " -I../../../ext"

if RUBY_PLATFORM =~ /darwin/
  $LDFLAGS << " -undefined dynamic_lookup"
end

create_makefile("with_buffer")

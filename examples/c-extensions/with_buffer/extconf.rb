require "mkmf"

# CA_WITH_BUFFER / rb_ca_call_with_buffer declared in ca_for_buffer.h, alongside
# carray.h.  Symbols are resolved at load time from carray_ext.bundle.
$CFLAGS << " -I../../../ext"

if RUBY_PLATFORM =~ /darwin/
  $LDFLAGS << " -undefined dynamic_lookup"
end

create_makefile("with_buffer")

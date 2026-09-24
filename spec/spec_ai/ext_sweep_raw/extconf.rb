require "mkmf"

# TEST FIXTURE for the raw sweep bridge (ca_call_cfunc_N / ca_call_cslab_N
# with caller-allocated outputs).  Symbols resolve at load time from the
# already-loaded carray_ext.bundle.
$CFLAGS << " -I../../../ext"

if RUBY_PLATFORM =~ /darwin/
  $LDFLAGS << " -undefined dynamic_lookup"
end

create_makefile("sweep_raw")

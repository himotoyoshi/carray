require "mkmf"

# Include carray's headers (ca_call_cfunc_*_r is declared in carray.h
# and resolved at load time from the already-loaded carray_ext.bundle).
$CFLAGS << " -I../../../ext"

# macOS: symbols are resolved at load time from carray_ext.bundle
# (loaded earlier via `require "carray"` in the same Ruby process).
# Linux: default shared-library symbol visibility handles this.
if RUBY_PLATFORM =~ /darwin/
  $LDFLAGS << " -undefined dynamic_lookup"
end

create_makefile("cfunc_r")

require "mkmf"

# Calls the public C surface of carray.h as a separately built extension
# would: without CARRAY_BUILD, resolving every symbol at load time from
# the already-loaded carray_ext bundle.
$CFLAGS << " -I../../../ext"

if RUBY_PLATFORM =~ /darwin/
  $LDFLAGS << " -undefined dynamic_lookup"
end

create_makefile("header_contract")

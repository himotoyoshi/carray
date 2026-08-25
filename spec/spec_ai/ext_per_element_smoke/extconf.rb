require "mkmf"

# TEST FIXTURE for the CA_FOR_EACH_ELEMENT macro family (ca_for_each_element.h,
# alongside carray.h).  Mirror of samples/c-extensions/per_element/.  Symbols
# resolve at load time from the already-loaded carray_ext.bundle.
$CFLAGS << " -I../../../ext"

if RUBY_PLATFORM =~ /darwin/
  $LDFLAGS << " -undefined dynamic_lookup"
end

create_makefile("per_element")

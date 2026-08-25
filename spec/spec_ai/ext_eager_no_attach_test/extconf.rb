require "mkmf"

# Include carray's headers (this test ext uses carray.h / ca_install_obj_type /
# ca_stride_func / ca_stride_setup, all extern in carray_ext.bundle).
$CFLAGS << " -I../../../ext"

# macOS: symbols (ca_stride_func, ca_install_obj_type, ...) are resolved
# at load time from the already-loaded carray_ext.bundle in the same Ruby
# process.  Linux: default shared-library symbol visibility handles this.
if RUBY_PLATFORM =~ /darwin/
  $LDFLAGS << " -undefined dynamic_lookup"
end

create_makefile("mock_unattachable")

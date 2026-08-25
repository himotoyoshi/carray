require "mkmf"

# xfer_smoke uses internal C symbols (ca_xfer_index / ca_xfer_addrs /
# ca_xfer_stride / ca_xfer_all / ca_fetch_index / ca_fetch_addr) which
# are extern in carray.h and resolved at load time from the
# already-loaded carray_ext.bundle.  This ext exists solely to keep the
# byte-level dispatcher parity / bench helpers out of release builds.
$CFLAGS << " -I../../../ext"

if RUBY_PLATFORM =~ /darwin/
  $LDFLAGS << " -undefined dynamic_lookup"
end

create_makefile("xfer_smoke")

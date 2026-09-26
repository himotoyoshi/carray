# spec_ai/test_installed_headers.rb
#
# A C extension built as its own gem sees only the headers that
# ext/extconf.rb lists in $INSTALLFILES.  A header left off that list still
# compiles inside this tree -- the examples and the spec fixtures all build
# with -I pointing at ext/ -- so nothing here notices until a downstream
# gem's #include fails.  That is how the sweep surface (ca_for_buffer.h,
# ca_for_each_element.h, ca_sweep_engine.h) and ca_triop_dispatch.h went
# out uninstalled.
#
# Three things are pinned here.
#
#   * Every header in ext/ is either installed or listed below as internal,
#     with the reason.  Adding a header means deciding which.
#   * Whatever an installed header includes is installed too.
#   * Every header the author docs and examples/c-extensions tell a reader
#     to #include is installed.

require "test/unit"

class TestInstalledHeaders < Test::Unit::TestCase

  ROOT = File.expand_path("../..", __dir__)
  EXT  = File.join(ROOT, "ext")

  # Headers deliberately not installed.  Each is used only by carray's own
  # translation units, or is documented as not installed.
  INTERNAL = {
    "carray_internal.h"         => "layer 3; documented as not installed",
    "version.h"                 => "documented as not installed",
    "carray_build_flags.h"      => "generated; exposed as CArray::BUILD_FLAGS",
    "ca_sort_kernels.h"         => "documented as not pulled into carray.h",
    "ca_composite_dispatch.h"   => "CAWindow / CATile / CARoll attach internals",
    "ca_op_powi.h"              => "helpers for the generated kernels",
    "ca_op_cmplx64.h"           => "helpers for the generated kernels",
    "ca_compare.h"              => "sort / search comparators",
    "ca_rng_normal.h"           => "random generator internals",
    "ca_rng_xoshiro256pp.h"     => "random generator internals",
    "carray_index_classifier.h" => "indexer internals",
    "carray_slab.h"             => "slab iterator internals",
  }

  def installed
    src = File.read(File.join(EXT, "extconf.rb"), encoding: "UTF-8")
    list = src.scan(/^\$INSTALLFILES << \['([^']+\.h)'/).flatten
    block = src[/%w\[(.*?)\]\.each do \|h\|\s*\$INSTALLFILES/m, 1]
    assert_not_nil block, "the %w[...] header list in ext/extconf.rb"
    list + block.split
  end

  def ext_headers
    Dir[File.join(EXT, "*.h")].map { |f| File.basename(f) }
  end

  def quoted_includes (path)
    File.read(path, encoding: "UTF-8").scan(/^\s*#\s*include\s+"([^"]+)"/).flatten
  end

  def test_every_header_is_installed_or_internal
    inst = installed
    undecided = ext_headers - inst - INTERNAL.keys
    assert_equal [], undecided.sort,
      "install it in ext/extconf.rb, or list it in INTERNAL with the reason"
    assert_equal [], (inst & INTERNAL.keys).sort
  end

  def test_installed_headers_include_only_installed_headers
    inst = installed
    ours = ext_headers
    missing = inst.select { |h| ours.include?(h) }.flat_map { |h|
      quoted_includes(File.join(EXT, h))
        .select { |i| ours.include?(i) && !inst.include?(i) }
        .map { |i| "#{h} -> #{i}" }
    }
    assert_equal [], missing
  end

  def test_documented_includes_are_installed
    inst = installed
    ours = ext_headers
    files = Dir[File.join(ROOT, "docs/authoring/*.md")] +
            Dir[File.join(ROOT, "guides/devel/*.md")] +
            Dir[File.join(ROOT, "examples/c-extensions/**/*.{c,h}")]
    missing = files.flat_map { |f|
      quoted_includes(f)
        .select { |i| ours.include?(i) && !inst.include?(i) }
        .map { |i| "#{f.delete_prefix(ROOT + "/")}: #{i}" }
    }
    assert_equal [], missing.uniq
  end

end

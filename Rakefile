#
#
#

GEMSPEC = "carray.gemspec"

begin
  require "yard"
  YARD::Rake::YardocTask.new(:yard)
rescue LoadError
  # yard gem not installed; `rake yard` will be unavailable.
end

desc "Check yard-stubs/ for drift against the live C extension"
task :stub_check => :build_ext do
  ruby "-I lib -I ext utils/check_stub_drift.rb" or exit($?.exitstatus)
end

desc "Check the kernel_iterator author surface for freeze drift (3.0+ pin)"
task :kernel_surface_check do
  ruby "utils/check_kernel_surface_freeze.rb" or exit($?.exitstatus)
end

task :install do
  spec = eval File.read(GEMSPEC)
  version_h = `ruby ext/version.rb`.chomp
  if spec.version.to_s != version_h
    STDERR.puts "Mismatch in version between carray.gemspec and version.h"
    STDERR.puts "  carray.gemspec - #{spec.version.to_s }"
    STDERR.puts "  version.h      - #{version_h}"
    STDERR.puts "Please check!"
    exit(1)
  end
  system %{
    gem build #{GEMSPEC}; gem install #{spec.full_name}.gem --no-document
  }
end

desc "Build C extension in-place (ext/extconf.rb -> Makefile -> make). " \
     "Set CARRAY_DEV=1 to enable smoke surface (see PROPOSAL_SMOKE_DEV_BUILD_GATE.md)"
task :build_ext do
  dev  = ENV["CARRAY_DEV"] == "1"
  arch = ENV["CARRAY_MARCH_NATIVE"] != "0"   # default on (matches extconf.rb)
  # Detect mode change via stamp file so we re-extconf when toggling
  # any build-mode flag between runs (otherwise the existing Makefile
  # keeps its old CFLAGS and either the smoke fences get stuck at the
  # previous state, or the SIMD codegen stays at the previous ISA
  # baseline). One compound key covers CARRAY_DEV + CARRAY_MARCH_NATIVE
  # — extend as needed if more build-mode toggles land.
  stamp = "ext/.dev_build_mode"
  prev = File.exist?(stamp) ? File.read(stamp).strip : nil
  curr = "#{dev ? 'dev' : 'release'}+#{arch ? 'march-native' : 'baseline'}"
  # Kernel regeneration lives in exactly one place, extconf.rb; the Makefile
  # does not touch it, which is what keeps a parallel make from racing over
  # the generated files.  So that editing mkkernel.rb during development is
  # not silently ignored, compare its mtime against carray_kernels.stamp here
  # and trigger need_extconf: the same mtime check inside extconf.rb then
  # fires and mkkernel runs, so regeneration is transparent.  A bare
  # `cd ext && make` is the caller's responsibility -- run extconf explicitly
  # after touching mkkernel.rb.
  kernels_stamp = "ext/carray_kernels.stamp"
  kernels_stale = File.exist?("ext/mkkernel.rb") && (
    !File.exist?(kernels_stamp) ||
    File.stat("ext/mkkernel.rb").mtime > File.stat(kernels_stamp).mtime
  )
  need_extconf = !File.exist?("ext/Makefile") || prev != curr || kernels_stale
  Dir.chdir("ext") do
    if need_extconf
      flags = []
      flags << "--enable-dev-build"     if dev
      flags << "--enable-march-native"  if arch
      sh "ruby extconf.rb #{flags.join(' ')}".strip
      File.write(".dev_build_mode", curr)
    end
    sh "make"
  end
end

desc "Clean C extension build artifacts in ext/"
task :clean_ext do
  Dir.chdir("ext") do
    sh "make distclean" if File.exist?("Makefile")
  end
  rm_f Dir["ext/carray_ext.{bundle,so}"]
  rm_rf Dir["ext/carray_ext.bundle.dSYM"]
end

require 'rspec/core/rake_task'
# Load the freshly built in-place extension (ext/) and the local lib/,
# not whatever stale carray_ext.bundle happens to be installed in the
# Ruby site_ruby tree.  Without this, rspec resolves `require 'carray'`
# against the installed gem, which can drift far behind the working
# tree (e.g. still expose pre-3.0 classes like CComplex) and produce
# bogus "pre-existing" failures.
RSpec::Core::RakeTask.new(:spec => :build_ext) do |t|
  t.ruby_opts = ["-Iext", "-Ilib"]
end

# A separately-compiled fixture / sample bundle must be rebuilt when its own
# source OR any carray public header changes.  The op table and all CArray
# struct layouts live in ext/*.h; growing e.g. ca_operation_function_t (Phase 0
# pool framework added struct_size/pool_bytes/pool_init) is an ABI break for
# these bundles because they hold the struct by value (`ca_mock_func =
# ca_stride_func` etc.).  A stale bundle then reads the new trailing fields as
# out-of-struct garbage -> garbage function-pointer call -> heap corruption,
# which surfaces as a heap-layout-sensitive crash in full spec_ai.  The .c
# mtime alone misses this (carray.h changed, the .c did not).  See the
# 2026-06-24 pool-framework fixture-staleness incident.
def fixture_stale? (bundle, src)
  return true if bundle.nil?
  newest_dep = ([src] + Dir["ext/*.h"]).map { |f| File.mtime(f) }.max
  newest_dep > File.mtime(bundle)
end

desc "Build spec/spec_ai/ext_memory_view_test/mv_borrower (rebuild if source/header newer than bundle)"
task :build_mv_borrower do
  dir = "spec/spec_ai/ext_memory_view_test"
  src = "#{dir}/mv_borrower.c"
  bundle = Dir["#{dir}/mv_borrower.{bundle,so}"].first
  if fixture_stale?(bundle, src)
    Dir.chdir(dir) do
      sh "make distclean" if File.exist?("Makefile")
      sh "ruby extconf.rb"
      sh "make"
    end
  end
end

desc "Build spec/spec_ai/ext_eager_no_attach_test/mock_unattachable (rebuild if source newer than bundle)"
task :build_mock_unattachable do
  dir = "spec/spec_ai/ext_eager_no_attach_test"
  src = "#{dir}/mock_unattachable.c"
  bundle = Dir["#{dir}/mock_unattachable.{bundle,so}"].first
  if fixture_stale?(bundle, src)
    Dir.chdir(dir) do
      sh "make distclean" if File.exist?("Makefile")
      sh "ruby extconf.rb"
      sh "make"
    end
  end
end

desc "Build spec/spec_ai/ext_xfer_smoke/xfer_smoke (rebuild if source newer than bundle)"
task :build_xfer_smoke do
  dir = "spec/spec_ai/ext_xfer_smoke"
  src = "#{dir}/xfer_smoke.c"
  bundle = Dir["#{dir}/xfer_smoke.{bundle,so}"].first
  if fixture_stale?(bundle, src)
    Dir.chdir(dir) do
      sh "make distclean" if File.exist?("Makefile")
      sh "ruby extconf.rb"
      sh "make"
    end
  end
end

# spec_ai-local smoke fixtures for the kernel-author surface.  These are
# byte-for-byte mirrors of samples/c-extensions/* kept under spec/spec_ai/ so the
# test suite owns its own build and never reaches into samples/ (samples/ is
# user-facing documentation, not a test dependency).
def build_spec_ai_smoke (dirname, basename)
  dir = "spec/spec_ai/#{dirname}"
  src = "#{dir}/#{basename}.c"
  bundle = Dir["#{dir}/#{basename}.{bundle,so}"].first
  if fixture_stale?(bundle, src)
    Dir.chdir(dir) do
      sh "make distclean" if File.exist?("Makefile")
      sh "ruby extconf.rb"
      sh "make"
    end
  end
end

desc "Build spec_ai author-surface smoke fixtures (cfunc_r / per_element / with_buffer / source / iter_source_kind)"
task :build_author_surface_smoke do
  build_spec_ai_smoke("ext_cfunc_r_smoke",     "cfunc_r")
  build_spec_ai_smoke("ext_per_element_smoke", "per_element")
  build_spec_ai_smoke("ext_with_buffer_smoke",   "with_buffer")
  build_spec_ai_smoke("ext_source_smoke",      "source_smoke")
  build_spec_ai_smoke("ext_iter_source_kind",  "iter_source_kind")
end

# NOTE: the tasks below build the user-facing examples under samples/.  They
# are intentionally NOT a spec_ai prerequisite (spec_ai uses its own fixtures
# above); run `rake build_c_extension_examples` manually to verify the docs
# examples still compile.
def build_c_extension_example (subdir, basename)
  dir = "samples/c-extensions/#{subdir}"
  src = "#{dir}/#{basename}.c"
  bundle = Dir["#{dir}/#{basename}.{bundle,so}"].first
  if fixture_stale?(bundle, src)
    Dir.chdir(dir) do
      sh "make distclean" if File.exist?("Makefile")
      sh "ruby extconf.rb"
      sh "make"
    end
  end
end

desc "Build samples/c-extensions/cfunc_r/cfunc_r (rebuild if source/header newer than bundle)"
task(:build_cfunc_r_example)       { build_c_extension_example("cfunc_r",     "cfunc_r") }

desc "Build samples/c-extensions/per_element/per_element (rebuild if source newer than bundle)"
task(:build_per_element_example)   { build_c_extension_example("per_element", "per_element") }

desc "Build samples/c-extensions/with_buffer/with_buffer (rebuild if source newer than bundle)"
task(:build_with_buffer_example)     { build_c_extension_example("with_buffer",   "with_buffer") }

desc "Build all samples/c-extensions/ examples"
task :build_c_extension_examples => [
  :build_cfunc_r_example,
  :build_per_element_example,
  :build_with_buffer_example,
]

desc "Run spec_ai tests (ruby -I ext -I lib)"
task :spec_ai => [:kernel_surface_check,
                  :build_ext, :build_mv_borrower, :build_mock_unattachable,
                  :build_xfer_smoke, :build_author_surface_smoke] do
  # macOS 13+ ships MallocZeroOnFree which zeros freed blocks -- masks any
  # ALLOC() user that relies on returned memory being zeroed.  Disable it so
  # Mac and Linux (glibc / no equivalent) exhibit the same recycled-garbage
  # behaviour during dev runs, keeping latent uninitialized-field bugs from
  # hiding on Mac.  This is what backs the rule that a view struct taken
  # from ALLOC() must have _pool set to NULL before its setup runs.
  ENV["MallocZeroOnFree"] ||= "0"
  sh "ruby -I ext -I lib -r test/unit -e 'Dir[\"spec/spec_ai/**/*.rb\"].sort.each{|f| require_relative f}'"
end

desc "Run the spec/UnitTest/ test-unit files (ruby -I ext -I lib)"
task :spec_unit => :build_ext do
  # Carried over from 2.x, and test-unit rather than RSpec, so neither the
  # :spec nor the :spec_ai glob picks these up.  Run them explicitly.
  sh "ruby -I ext -I lib -r test/unit -e 'Dir[\"spec/UnitTest/*.rb\"].sort.each{|f| require_relative f}'"
end

desc "Run every test suite and the stub drift check"
task :test => [:spec_ai, :spec, :spec_unit, :stub_check]

task :default => :test


namespace :pdf do
  require "date"

  # src_dir: guides/devel etc.  out: path to pdf.  title / subtitle: cover page text.
  def build_md_bundle_pdf(src_dir:, out:, title:, subtitle:)
    sources = Dir.glob(File.join(src_dir, "*.md")).sort
                 .reject { |f| File.basename(f) == "README.md" }
    raise "no .md files under #{src_dir}" if sources.empty?

    require "tmpdir"
    Dir.mktmpdir("carray-pdf-") do |tmp|
      bundle = File.join(tmp, "bundle.md")
      File.open(bundle, "w") do |io|
        # cover page
        io.puts %(<div style="text-align:center; padding-top:25vh;">)
        io.puts
        io.puts %(<h1 style="font-size:2.4em; margin-bottom:0.4em;">#{title}</h1>)
        io.puts
        io.puts %(<p style="font-size:1.2em; color:#666;">#{subtitle}</p>)
        io.puts
        io.puts %(<p style="margin-top:3em; color:#999;">Generated #{Date.today}</p>)
        io.puts
        io.puts %(</div>)
        io.puts
        io.puts %(<div style="page-break-after: always;"></div>)
        io.puts

        # plain (non-linked) table of contents
        io.puts "# Contents"
        io.puts
        sources.each do |f|
          first_h1 = File.foreach(f).find { |l| l.start_with?("# ") }
          label = first_h1 ? first_h1.sub(/^#\s+/, "").strip : File.basename(f, ".md")
          io.puts "- #{label}"
        end
        io.puts
        io.puts %(<div style="page-break-after: always;"></div>)
        io.puts

        # body
        sources.each do |f|
          io.write File.read(f)
          io.puts
          io.puts
          io.puts %(<div style="page-break-after: always;"></div>)
          io.puts
        end
      end

      mkdir_p File.dirname(out)
      font_size = ENV["FONT_SIZE"] || "12pt"
      css = "body { font-size: #{font_size}; line-height: 1.5; } " \
            "code, pre, pre code, p code, li code, td code, h1 code, h2 code, h3 code, h4 code " \
            "{ font-size: 10pt !important; } " \
            "h1 { font-size: 1.7em; } h2 { font-size: 1.35em; } h3 { font-size: 1.15em; } " \
            "th, td { padding: 3px 6px !important; }"
      pdf_opts = %q({"margin":{"top":"12mm","bottom":"14mm","left":"12mm","right":"12mm"}})
      sh "md-to-pdf", "--css", css, "--pdf-options", pdf_opts, bundle
      mv bundle.sub(/\.md\z/, ".pdf"), out
    end
  end

  desc "Bundle guides/devel into a single PDF (Developer's Guide). md-to-pdf required."
  task :devel do
    build_md_bundle_pdf(
      src_dir:  "guides/devel",
      out:      "guides/pdf/CArray-Developer-Guide.pdf",
      title:    "CArray Developer's Guide",
      subtitle: "guides/devel — bundled edition",
    )
  end

  desc "Bundle guides/users into a single PDF (User's Guide). md-to-pdf required."
  task :users do
    build_md_bundle_pdf(
      src_dir:  "guides/users",
      out:      "guides/pdf/CArray-Users-Guide.pdf",
      title:    "CArray User's Guide",
      subtitle: "guides/users — bundled edition",
    )
  end

  desc "Bundle both developer and user guides."
  task :all => [:devel, :users]
end

# ---------------------------------------------------------------------------
# Unified benchmark suite (benchmark/). The tasks live in benchmark/tasks.rake
# because benchmark/ is a development tool that is not published; when it is
# absent this simply defines nothing.
# ---------------------------------------------------------------------------
bench_tasks = File.expand_path("benchmark/tasks.rake", __dir__)
load bench_tasks if File.exist?(bench_tasks)

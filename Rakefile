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

# The repo root should hold nothing but what git tracks.  A generator run from
# the wrong directory drops its output here -- extconf.rb outside ext/, a guide
# example that writes a file -- and adding the name to .gitignore hides it for
# good instead of stopping it.  Name the strays instead.
ROOT_LOCAL = %w[
  .git .envrc .claude .yardoc .yard-html devel benchmark CLAUDE.md
].freeze

def root_strays
  tracked = `git ls-files -z`.split("\0").map { |p| p[%r{\A[^/]+}] }.uniq
  keep = tracked + ROOT_LOCAL
  Dir.children(".").reject { |e| keep.include?(e) || e.end_with?(".gem") }.sort
end

desc "Name the files at the repo root that no generator should have left there"
task :tidy do
  strays = root_strays
  if strays.empty?
    puts "The repo root holds only what git tracks."
  else
    puts "Left at the repo root (`rake tidy:clean` removes them):"
    strays.each { |e| puts "  #{e}" }
  end
end

namespace :tidy do
  desc "Remove them"
  task :clean do
    strays = root_strays
    puts "The repo root holds only what git tracks." if strays.empty?
    rm_rf strays unless strays.empty?
  end
end

desc "Check the kernel_iterator author surface for freeze drift (3.0+ pin)"
task :kernel_surface_check do
  ruby "utils/check_kernel_surface_freeze.rb" or exit($?.exitstatus)
end

desc "Check that the Face rules are called through the parts in ext/ca_obj_face.c"
task :face_parts_check do
  ruby "utils/check_face_parts.rb" or exit($?.exitstatus)
end

desc "Check that an axis taken from Ruby is read by ca_normalize_axis_arg"
task :axis_normalize_check do
  ruby "utils/check_axis_normalize.rb" or exit($?.exitstatus)
end

desc "Check that a rank is held to CA_RANK_MAX by ca_check_rank_fits"
task :rank_limit_check do
  ruby "utils/check_rank_limit.rb" or exit($?.exitstatus)
end

desc "Check that an error's method name comes from ca_calling_method_name"
task :method_naming_check do
  ruby "utils/check_method_naming.rb" or exit($?.exitstatus)
end

desc "Check that no file of lib gains a define_method, whose frame names nothing"
task :define_method_check do
  ruby "utils/check_define_method.rb" or exit($?.exitstatus)
end

desc "Check that no file of ext gains a raise that does not name the method"
task :unnamed_raise_check do
  ruby "utils/check_unnamed_raises.rb" or exit($?.exitstatus)
end

desc "Check that a write into a read-only array is refused by ca_refuse_read_only"
task :read_only_refusal_check do
  ruby "utils/check_read_only_refusal.rb" or exit($?.exitstatus)
end

desc "Check that a frame verb over the columns runs through CAFrame::ColumnVerbs"
task :frame_column_verbs_check do
  ruby "utils/check_frame_column_verbs.rb" or exit($?.exitstatus)
end

desc "Check that a repeated column name is refused by CAFrame.refuse_repeated_names"
task :frame_repeated_names_check do
  ruby "utils/check_frame_repeated_names.rb" or exit($?.exitstatus)
end

desc "Check that a frame key is read through CAFrame#key_column"
task :frame_keys_check do
  ruby "utils/check_frame_keys.rb" or exit($?.exitstatus)
end

desc "Check that a column name is refused by CAFrame.column_key"
task :frame_column_names_check do
  ruby "utils/check_frame_column_names.rb" or exit($?.exitstatus)
end

desc "Check that a type is named through CArray::Inspector.type_label"
task :type_label_check do
  ruby "utils/check_type_label.rb" or exit($?.exitstatus)
end

desc "Check that no file gains a hand-written IndexError"
task :index_error_check do
  ruby "utils/check_index_errors.rb" or exit($?.exitstatus)
end

desc "Check that no file gains a RuntimeError a caller could cause"
task :runtime_error_check do
  ruby "utils/check_runtime_errors.rb" or exit($?.exitstatus)
end

desc "Check that every odometer walk says how it skips an empty extent"
task :empty_walk_check do
  ruby "utils/check_empty_walks.rb" or exit($?.exitstatus)
end

desc "Check that a cast to another array's data type says why that side is the authority"
task :one_sided_cast_check do
  ruby "utils/check_one_sided_cast.rb" or exit($?.exitstatus)
end

desc "Check that no Ruby value is narrowed into an integer cell by a C cast"
task :integer_store_check do
  ruby "utils/check_integer_store_narrowing.rb" or exit($?.exitstatus)
end

desc "Check that a constructor checks its arguments before it allocates"
task :setup_before_alloc_check do
  ruby "utils/check_setup_before_alloc.rb" or exit($?.exitstatus)
end

desc "Check that a step that can raise is undone through a part"
task :protect_parts_check do
  ruby "utils/check_protect_parts.rb" or exit($?.exitstatus)
end

desc "Check that no view setup asks its parent for a mask"
task :view_setup_mask_check do
  ruby "utils/check_view_setup_mask.rb" or exit($?.exitstatus)
end

desc "Report memory a raise leaves behind across every public method (macOS, slow)"
task :leak_matrix do
  ruby "-Iext", "-Ilib", "utils/leak_matrix.rb" or exit($?.exitstatus)
end

desc "Check that whether a kernel can raise on a cell is decided by one part"
task :cell_raise_check do
  ruby "utils/check_cell_raise.rb" or exit($?.exitstatus)
end

desc "Check that a row's code for several key columns is made by one part"
task :key_codes_check do
  ruby "utils/check_key_codes.rb" or exit($?.exitstatus)
end

desc "Check that the type a value query meets its reference in is decided by one part"
task :query_match_check do
  ruby "utils/check_query_match.rb" or exit($?.exitstatus)
end

desc "Check that the order of NaN is decided by the parts, not written by hand"
task :nan_order_check do
  ruby "utils/check_nan_order.rb" or exit($?.exitstatus)
end

desc "Check that a mask stand-in is made, read and settled only through the parts"
task :mask_standin_check do
  ruby "utils/check_mask_standins.rb" or exit($?.exitstatus)
end

desc "Check that a buffer for an array's cells is valid before it is published"
task :cell_buffer_check do
  ruby "utils/check_cell_buffers.rb" or exit($?.exitstatus)
end

desc "Check that every attach window opened by hand says why it is safe"
task :attach_window_check do
  ruby "utils/check_attach_windows.rb" or exit($?.exitstatus)
end

desc "Check that every method named like __x__ is on utils/dunder_methods.txt"
task :dunder_method_check => :build_ext do
  ruby "-Iext", "-Ilib", "utils/check_dunder_methods.rb" or exit($?.exitstatus)
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
     "Set CARRAY_DEV=1 to enable the smoke surface (dev builds only)"
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
  # ca_op_powi.h is an input too: the generator copies part of it into the
  # build (CArray.__kernel_helpers__).
  kernels_stamp = "ext/carray_kernels.stamp"
  kernels_inputs = %w[ext/mkkernel.rb ext/ca_op_powi.h]
  kernels_stale = File.exist?("ext/mkkernel.rb") && (
    !File.exist?(kernels_stamp) ||
    kernels_inputs.any? { |f| File.stat(f).mtime > File.stat(kernels_stamp).mtime }
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
  strays = root_strays
  unless strays.empty?
    warn "note: the repo root holds #{strays.join(', ')} -- see `rake tidy`"
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
# byte-for-byte mirrors of examples/c-extensions/* kept under spec/spec_ai/ so the
# test suite owns its own build and never reaches into examples/ (examples/ is
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

desc "Build spec_ai author-surface smoke fixtures (cfunc_r / with_buffer / source / iter_source_kind / header_contract / address_basis_c)"
task :build_author_surface_smoke do
  build_spec_ai_smoke("ext_cfunc_r_smoke",     "cfunc_r")
  build_spec_ai_smoke("ext_cslab_smoke",       "cslab")
  build_spec_ai_smoke("ext_sweep_raw",         "sweep_raw")
  build_spec_ai_smoke("ext_with_buffer_smoke",   "with_buffer")
  build_spec_ai_smoke("ext_source_smoke",      "source_smoke")
  build_spec_ai_smoke("ext_iter_source_kind",  "iter_source_kind")
  build_spec_ai_smoke("ext_header_contract",   "header_contract")
  build_spec_ai_smoke("ext_address_basis",     "address_basis_c")
end

# NOTE: the tasks below build the user-facing examples under examples/.  They
# are intentionally NOT a spec_ai prerequisite (spec_ai uses its own fixtures
# above); run `rake build_c_extension_examples` manually to verify the docs
# examples still compile.
def build_c_extension_example (subdir, basename)
  dir = "examples/c-extensions/#{subdir}"
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

desc "Build examples/c-extensions/cfunc_r/cfunc_r (rebuild if source/header newer than bundle)"
task(:build_cfunc_r_example)       { build_c_extension_example("cfunc_r",     "cfunc_r") }

desc "Build examples/c-extensions/cslab/cslab (rebuild if source/header newer than bundle)"
task(:build_cslab_example)         { build_c_extension_example("cslab",       "cslab") }

desc "Build examples/c-extensions/with_buffer/with_buffer (rebuild if source newer than bundle)"
task(:build_with_buffer_example)     { build_c_extension_example("with_buffer",   "with_buffer") }

desc "Build all examples/c-extensions/ examples"
task :build_c_extension_examples => [
  :build_cfunc_r_example,
  :build_cslab_example,
  :build_with_buffer_example,
]

# spec_ai runs its files in several processes at once (SPEC_JOBS, default
# up to 8; SPEC_JOBS=1 runs them all in one process as before).  The files
# are dealt out largest first into four bundles per process, so each bundle
# mixes heavy and light files, and the processes take bundles off a queue.
# A file that measures the process's memory (resident size, or the malloc
# zone in use) sees the load of the other processes, so it runs alone after
# the rest.
SPEC_AI_ALONE = ["spec/spec_ai/test_iter_raise_cleanup.rb",
                 "spec/spec_ai/test_copy_raise_cleanup.rb"]

SPEC_AI_COMMAND = ["ruby", "-I", "ext", "-I", "lib", "-r", "test/unit",
                   "-r", "./spec/spec_ai/attach_balance.rb", "-e",
                   "files = ARGV.dup; ARGV.clear; files.each { |f| require File.expand_path(f) }"]

SPEC_AI_SUMMARY = /(\d+) tests, (\d+) assertions, (\d+) failures, (\d+) errors, (\d+) pendings, (\d+) omissions, (\d+) notifications/

def run_spec_ai_bundle (files)
  require "open3"
  out, status = Open3.capture2e(*SPEC_AI_COMMAND, *files)
  counts = (m = out.scan(SPEC_AI_SUMMARY).last) ? m.map(&:to_i) : nil
  ok = status.success? && counts && counts[2] == 0 && counts[3] == 0
  { files: files, out: out, counts: counts, ok: ok, status: status }
end

def run_spec_ai_parallel (files, jobs)
  started = Time.now
  alone, rest = files.partition { |f| SPEC_AI_ALONE.include?(f) }
  bundles = Array.new([jobs * 4, rest.size].min) { [] }
  rest.sort_by { |f| -File.size(f) }.each_with_index { |f, i| bundles[i % bundles.size] << f }
  queue = Queue.new
  bundles.sort_by { |b| -b.sum { |f| File.size(f) } }.each { |b| queue << b }
  results = Queue.new
  workers = Array.new(jobs) do
    Thread.new do
      while (b = (queue.pop(true) rescue nil))
        r = run_spec_ai_bundle(b)
        results << r
        print(r[:ok] ? "." : "F")
      end
    end
  end
  workers.each(&:join)
  results << run_spec_ai_bundle(alone).tap { |r| print(r[:ok] ? "." : "F") } unless alone.empty?
  puts
  all = Array.new(results.size) { results.pop }
  all.reject { |r| r[:ok] }.each do |r|
    puts "=" * 72
    puts "Failed bundle (exit #{r[:status].exitstatus.inspect}#{r[:counts] ? "" : ", no summary: crashed"}):"
    puts r[:files].map { |f| "  #{f}" }
    puts r[:out]
  end
  sums = all.map { |r| r[:counts] || [0] * 7 }.transpose.map(&:sum)
  printf "%d tests, %d assertions, %d failures, %d errors, %d pendings, %d omissions, %d notifications\n", *sums
  printf "%d files in %d bundles, %d processes at a time, %.1f s\n", files.size, all.size, jobs, Time.now - started
  failed = all.reject { |r| r[:ok] }
  fail "spec_ai: #{failed.size} bundle(s) failed" unless failed.empty?
end

desc "Run spec_ai tests (ruby -I ext -I lib, SPEC_JOBS processes at once)"
task :spec_ai => [:kernel_surface_check, :attach_window_check, :face_parts_check,
                  :runtime_error_check, :index_error_check, :axis_normalize_check, :rank_limit_check, :method_naming_check, :define_method_check, :unnamed_raise_check, :read_only_refusal_check, :frame_column_verbs_check, :frame_repeated_names_check, :frame_keys_check, :frame_column_names_check, :type_label_check, :cell_buffer_check,
                  :view_setup_mask_check, :protect_parts_check,
                  :setup_before_alloc_check, :integer_store_check, :one_sided_cast_check,
                  :empty_walk_check, :mask_standin_check, :nan_order_check, :query_match_check, :key_codes_check, :cell_raise_check,
                  :build_ext, :dunder_method_check,
                  :build_mv_borrower, :build_mock_unattachable,
                  :build_xfer_smoke, :build_author_surface_smoke] do
  # macOS 13+ ships MallocZeroOnFree which zeros freed blocks -- masks any
  # ALLOC() user that relies on returned memory being zeroed.  Disable it so
  # Mac and Linux (glibc / no equivalent) exhibit the same recycled-garbage
  # behaviour during dev runs, keeping latent uninitialized-field bugs from
  # hiding on Mac.  This is what backs the rule that a view struct taken
  # from ALLOC() must have _pool set to NULL before its setup runs.
  ENV["MallocZeroOnFree"] ||= "0"
  # test_*.rb, not every .rb: the fixture directories hold their own
  # extconf.rb, and requiring one of those runs mkmf here -- compiler probes
  # during the test run, and a Makefile / mkmf.log left at the repo root.
  # Their helper (ext_xfer_smoke/load.rb) is pulled in by the tests that need
  # it, so it does not want collecting either.
  # attach_balance.rb checks around every test that no view was left
  # attached (development builds only).
  require "etc"
  files = Dir["spec/spec_ai/**/test_*.rb"].sort
  jobs = Integer(ENV["SPEC_JOBS"] || [Etc.nprocessors, 8].min)
  if jobs <= 1
    sh(*SPEC_AI_COMMAND, *files)
  else
    run_spec_ai_parallel(files, jobs)
  end
end

desc "Run spec_ai with every fast path switched off (development builds only)"
task :spec_ai_general do
  # A fast path answers by a different algorithm what a general path also
  # answers.  CARRAY_GENERAL_PATH=1 makes a development build take the
  # general path everywhere, so this run and spec_ai compare the two.
  ENV["CARRAY_GENERAL_PATH"] = "1"
  Rake::Task[:spec_ai].invoke
end

desc "Run spec_ai with the kernel iterator delivering every source by transfer"
task :spec_ai_transfer do
  # CARRAY_GENERAL_PATH=2 also switches the fast paths off, and makes the
  # kernel iterator gather every source through the view's own transfer
  # (ca_xfer_all) -- the walk that keeps no promise of its own.  This run,
  # spec_ai_general and spec_ai compare the iterator's routes with it.
  ENV["CARRAY_GENERAL_PATH"] = "2"
  Rake::Task[:spec_ai].invoke
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
    # Chapters are numbered and so sort into reading order on their own.
    # Front matter carries no number -- it is not chapter zero -- so name it
    # here and put it ahead of them.
    front_matter = %w[introduction.md]
    chapters = Dir.glob(File.join(src_dir, "*.md")).sort
                  .reject { |f| File.basename(f) == "README.md" }
                  .reject { |f| front_matter.include?(File.basename(f)) }
    sources = front_matter.map { |n| File.join(src_dir, n) }.select { |f| File.exist?(f) } + chapters
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

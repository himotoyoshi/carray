#
# extconf.rb for Ruby/CArray
#

$top_srcdir = ""

require 'mkmf'
require 'rbconfig'

#
# from mkmf.rb
#
def create_header(header = "extconf.h")
  message "creating %s\n", header
  sym = header.tr("a-z./\055", "A-Z___")
  hdr = ["#ifndef #{sym}\n#define #{sym}\n"]
  for line in $defs
    case line
    when /^-D(SIZEOF_[^=]+)(?:=(.*))?/
      hdr << "#ifndef #$1\n#define #$1 #{$2 ? Shellwords.shellwords($2)[0].gsub(/(?=\t+)/, "\
\\n") : 1}\n#endif\n"
    when /^-D([^=]+)(?:=(.*))?/
      hdr << "#define #$1 #{$2 ? Shellwords.shellwords($2)[0].gsub(/(?=\t+)/, "\
\\n") : 1}\n"
    when /^-U(.*)/
      hdr << "#undef #$1\n"
    end
  end
  hdr << "#endif\n"
  hdr = hdr.join
  unless (IO.read(header) == hdr rescue false)
    open(header, "wb") do |hfile|
      hfile.write(hdr)
    end
  end
  $extconf_h = header
end

# --- ruby version code ---


# --- add option "--sitelibdir=dir" ---

if String === (optarg = arg_config("--sitelibdir"))
  dir = File.expand_path(optarg)
  if File.exist?(dir)
    CONFIG['sitelibdir'] = dir
  else
    raise "invalid sitelibdir specified"
  end
end

# --- add option "--with-cc=cc"

if String === (optarg = arg_config("--with-cc"))
  CONFIG['CC'] = optarg
  if CONFIG['LDSHARED'] =~ /^cc /
    CONFIG['LDSHARED'].sub!(/^cc/, optarg)
  end
end

# --- seting $CFLAGS

$CFLAGS += " -Wall"

# --- the flags that decide the numbers
#
# Two compilations of the same C do not have to agree on the last bit: what
# the compiler is allowed to fuse or reorder is decided by the flags it was
# given.  Anything computing what these kernels compute, somewhere other
# than in them, has to be built the same way to arrive at the same answer,
# so the flags that bear on it are recorded and handed out as
# CArray::BUILD_FLAGS.  Optimisation and architecture only -- warnings,
# defines and link options change nothing about the arithmetic.
$carray_build_flags = [RbConfig::CONFIG["optflags"].to_s.strip]

# --- in-build flag (CARRAY_BUILD)
#
# Marks a translation unit as part of carray itself, i.e. recompiled whenever
# ext/*.h changes.  carray.h uses it to hand out the inline form of accessors
# that depend on struct layout (ca_is_entity indexes ca_func[], whose stride
# is sizeof(ca_operation_function_t)).  Extensions built separately get the
# out-of-line form instead, so adding an operation-table slot cannot silently
# re-index the table underneath them.
#
# The fixtures under spec/spec_ai/ext_* deliberately do NOT set this -- they
# stand in for external extensions and should exercise the same surface.
#
# See devel/PROPOSAL_PARTIAL_FILL_WHOLE_ROOT_WRITEBACK.md section 6.1
#
$CFLAGS += " -DCARRAY_BUILD"

# --- dev-only build flag (CARRAY_DEV_BUILD)
#
# When `--enable-dev-build` is passed (or `rake build_ext` is invoked with
# CARRAY_DEV=1), define CARRAY_DEV_BUILD.  This unlocks the smoke surface
# in ext/*.c (gated by #ifdef CARRAY_DEV_BUILD at the tail of each file
# + Init_ registration block) so spec_ai regression pins can run.
#
# Release builds (default) leave CARRAY_DEV_BUILD undefined → smoke fences
# compile to nothing → user-facing binary has no smoke API exposed.
#
# See devel/PROPOSAL_SMOKE_DEV_BUILD_GATE.md
#
if enable_config("dev-build", false)
  $CFLAGS += " -DCARRAY_DEV_BUILD"
  $stderr.puts "carray: CARRAY_DEV_BUILD enabled (smoke surface available)"
end

# --- probe for `-fopenmp-simd` (SL.1.0, PROPOSAL_REDUCTION_SIMD_LICENSE)
#
# `-fopenmp-simd` enables `#pragma omp simd` (and its `reduction(+:acc)`
# clause) without pulling in libomp.  Used by SL.1.1+ contig-branch
# variants in CA_SLAB_REDUCE_T_{PLUS,MIN,MAX,STAR,VAR}_EX to let
# the compiler reassoc the reduction accumulator into SIMD lanes
# (worth ~5-8x on f64 reduction hot paths, per PoC bench 2026-06-12).
#
# - Apple clang / gcc 4.9+ / clang 3.9+ : supported.
# - MSVC / older compilers              : probe fails, flag omitted,
#                                         pragma silently ignored,
#                                         code stays correct (graceful).
#
# Q1 closure (sparring round 1 2026-06-12): (A) try_compile.
#
simd_probe = <<~C
  int main(void) {
    double x = 0;
    #pragma omp simd reduction(+:x)
    for (int i = 0; i < 10; i++) x += i;
    return (int)x;
  }
C
if try_compile(simd_probe, "-fopenmp-simd")
  $CFLAGS += " -fopenmp-simd"
  $carray_build_flags << "-fopenmp-simd"
  $stderr.puts "carray: -fopenmp-simd enabled (SIMD reduction license)"
end

# --- probe for `-march=native` (opt-in)
#
# Widens SIMD codegen to whatever ISA extensions the build-machine CPU
# supports — AVX / AVX2 / AVX-512 on x86_64, SVE on newer aarch64.
#
# Default: on.  Ruby gems are install-on-target — `gem install carray`
# runs extconf + gcc/clang on the machine that will also run the
# compiled binary, so build CPU == run CPU by construction and there
# is no cross-generation deployment risk.  Baseline-SSE2 build on an
# AVX2/AVX-512 x86_64 box under-reports by 2-4x on reduction / element-
# wise kernels (observed 2026-07-18: i7-14700K bench showed no `vaddpd`,
# only `addpd` + `addsd`, AVX2 completely dormant), which is not what
# most users want.
#
# Opt out (only needed when building a portable pre-built binary gem
# meant to run on older CPUs than the build machine):
#   ruby extconf.rb --disable-march-native
#   CARRAY_MARCH_NATIVE=0 rake build_ext
#
# Probe uses try_compile with a trivial program; unsupported compilers
# fail the probe gracefully and stay on the baseline ISA.
#
default_on = ENV["CARRAY_MARCH_NATIVE"] != "0"
if enable_config("march-native", default_on)
  arch_probe = "int main(void) { return 0; }\n"
  if try_compile(arch_probe, "-march=native")
    $CFLAGS += " -march=native"
    $carray_build_flags << "-march=native"
    $stderr.puts "carray: -march=native enabled (build-machine ISA extensions)"
  else
    $stderr.puts "carray: -march=native probe FAILED, keeping baseline SIMD"
  end
end
File.write("carray_build_flags.h",
           "/* GENERATED by extconf.rb: the flags this build's arithmetic\n" \
           "   was compiled with.  See CArray::BUILD_FLAGS. */\n" \
           "#define CA_BUILD_FLAGS #{$carray_build_flags.join(" ").inspect}\n")

# $CFLAGS += " -m128bit-long-double"  ### gcc only
# $CFLAGS += " -Wno-absolute-value"
# $LDFLAGS += " -L/usr/local/opt/llvm/lib -Wl,-rpath,/usr/local/opt/llvm/lib"

# --- check data types

header = ["ruby.h"]

if have_header("sys/types.h")
  header.push "sys/types.h"
end

if have_header("stdint.h")
  header.push "stdint.h"
end

have_type("int8_t",   header)
have_type("uint8_t",  header)
have_type("int16_t",  header)
have_type("uint16_t", header)
have_type("int32_t",  header)
have_type("uint32_t", header)
have_type("int64_t",  header)
have_type("uint64_t", header)

have_type("long long", header)
have_type("float", header)
have_type("double", header)
# long double / long double complex were retired in carray-3.0
# (DROP_LONGDOUBLE); no probes needed.
if have_header("complex.h")
  complex_h = "complex.h"
  have_type("float complex",  complex_h)
  have_type("double complex", complex_h)
else
  complex_h = nil
end

# --- check tgmath.h

have_header("tgmath.h")
have_func("atan2",  "math.h")
have_func("hypot",  "math.h")
have_func("lgamma", "math.h")
have_func("expm1",  "math.h")

# --- check mergesort routine

have_func("mergesort", "stdlib.h")

# --- check mergesort routine

have_func("strptime", "time.h")

# --- check raneg object

have_func("rb_arithmetic_sequence_extract")

# --- check MemoryView protocol (Ruby 3.0+ required) ---

unless have_header("ruby/memory_view.h")
  raise "ruby/memory_view.h not found; Ruby 3.0+ is required"
end

# --- setup install files

$INSTALLFILES = []
$INSTALLFILES << ['carray.h', '$(archdir)']
$INSTALLFILES << ['carray_config.h', '$(archdir)']

# --- ext-author / math-backend surface (PROPOSAL_CARRAY_H_REORG H.1)
#
# Two reasons a header belongs here, and only these two.
#
# (a) Reachable from `#include "carray.h"`.  carray.h is a public umbrella
#     that pulls carray_math_kernel.h and ca_kernel_iterator.h, which in
#     turn pull the per-family dispatch headers and the iterator
#     substrate.  Every header in that transitive closure must ship, or a
#     downstream gem's `#include "carray.h"` fails to resolve.
#
# (b) Not in the closure, but written for ext authors to include
#     explicitly.  ca_obj_face.h is the Face authoring surface: an
#     external gem defines its own Face by including it directly.
#
# A header that is neither is internal, however useful it looks in-tree.
# ca_op_powi.h (op_powi_<type> helpers for the generated kernels) and
# ca_composite_dispatch.h (per-region gather/scatter routines behind
# CAWindow / CATile / CARoll attach) are consumed only by carray's own
# translation units, each of which includes them directly; shipping them
# would promote unstable internals to a downstream contract, so they stay
# out.  carray_internal.h (layer 3) is likewise never installed.
#
%w[
  carray_math_kernel.h
  carray_call_cfunc.h
  ca_axis_descriptor.h
  ca_monop_dispatch.h
  ca_binop_dispatch.h
  ca_bincmp_dispatch.h
  ca_moncmp_dispatch.h
  ca_kernel_iterator.h
  ca_iter_substrate.h
  ca_obj_face.h
].each do |h|
  $INSTALLFILES << [h, '$(archdir)']
end

# --- cygwin/mingw
#
# Installing the static link library "libcarray.a".
# This technique is based on extconf.rb in Ruby/NArray distribution.
#

if /cygwin|mingw/ =~ RUBY_PLATFORM
  sitearchdir = RbConfig::CONFIG["sitearchdir"]
  $DLDFLAGS << " -L#{sitearchdir} -Wl,--out-implib=libcarray.a "
  unless File.exist? "libcarray.a"
    $TOUCHED_LIBCARRAY_A = true
    open("libcarray.a", "w") {}
  end
  $INSTALLFILES << ['libcarray.a', '$(archdir)']
end

# --- create carray_config.h
#
# Creating "carray_config.h".
#

config_h = "carray_config.h"
create_header(config_h)

$defs = [] # Now these definitions are in carray_config.h.

# --- generated sources

if ( not File.exist?("carray_cast_func.c") ) or
    File.stat("carray_cast_func.rb").mtime > File.stat("carray_cast_func.c").mtime
  system("ruby carray_cast_func.rb > carray_cast_func.c")
end

# The kernels are generated as 15 files (10 kinds, with reduce split into 5
# sub-groups, plus an aggregator init.c) rather than one carray_kernels.c,
# which is what lets a parallel make actually parallelise.  They land flat in
# ext/ so mkmf picks them up as $srcs.
#
# Generation happens here and only here; the Makefile does not regenerate
# anything.  On the gem-install path that reads extconf -> mkkernel -> make
# compiling static sources, which is one pass with no race.
#
# carray_kernels.stamp is the mtime witness:
#   - here: regenerate and touch it when mkkernel.rb is newer
#   - in the Rakefile (rake build_ext): the same stamp triggers need_extconf
CARRAY_KERNELS_STAMP = "carray_kernels.stamp"
if ( not File.exist?(CARRAY_KERNELS_STAMP) ) or
    File.stat("mkkernel.rb").mtime > File.stat(CARRAY_KERNELS_STAMP).mtime
  # passing "." makes the generator write the split files into ext/
  unless system("ruby mkkernel.rb .")
    raise "mkkernel.rb failed to generate split kernel files"
  end
  require "fileutils"
  FileUtils.touch(CARRAY_KERNELS_STAMP)
end
# clear out a single-stream carray_kernels.c left over from an older
# checkout; having both would give duplicate definitions
if File.exist?("carray_kernels.c")
  File.unlink("carray_kernels.c")
end
# Fail here rather than at link time if the generator produced nothing.
if Dir.glob("carray_kernels_*.c").empty?
  raise "no carray_kernels_*.c files found after mkkernel.rb; check the generator"
end

if ( not File.exist?("carray_call_cfunc.c") ) or
    ( not File.exist?("carray_call_cfunc.h") ) or
    File.stat("mk_call_cfunc.rb").mtime > File.stat("carray_call_cfunc.c").mtime
  system("ruby mk_call_cfunc.rb")
end

# --- create Makefile

create_makefile("carray_ext")

# --- remove dummy 'libcarray.a' for cygwin/mingw

if $TOUCHED_LIBCARRAY_A
  File.unlink("libcarray.a")
end

# --- modify Makefile

makefile_orig = File.read("Makefile")

mk = open("Makefile", "w") 
mk.puts makefile_orig

mk.write <<HERE_END
CA_VERSION = ${shell ${RUBY} version.rb}
GEMFILE    = carray-${CA_VERSION}.gem

carray_cast_func.c: carray_cast_func.rb
	${RUBY} carray_cast_func.rb > carray_cast_func.c

# P.5b.5: ext/mkmath.rb / ext/carray_math.rb retired (= residual hand-
# written ipower wrappers + lazy ipower kernel table now live in
# ext/ca_op_ipower.c, single file, no generation).  No Makefile rule
# needed.

# There is deliberately no kernel-regeneration rule in the Makefile.  Running
# mkkernel.rb belongs to the pre-generation block above, which is idempotent
# through carray_kernels.stamp.
#
# Two things went wrong when the Makefile did own it:
#   - `carray_kernels_init.c: mkkernel.rb` declares one target for a recipe
#     that writes 15 files.  Under a parallel make on a filesystem with fine
#     mtime granularity this raced: intermittent build failures
#     (`as: can't create ... reduce_aggregate.o`) or the same file compiled
#     twice.  It showed up on Linux during gem install; on macOS the
#     filesystem timing hid it.
#   - Routing the rule through a stamp file does not help either: GNU make
#     treats a no-recipe dependency as a reason to skip re-checking the mtime
#     of the downstream .o, so a fresh .c can sit next to a stale .o and the
#     build still reports success.
#
# Who does what now:
#   - gem install: extconf.rb runs mkkernel, make compiles static sources.
#     One pass, nothing to race.
#   - `rake build_ext`: the Rakefile compares mkkernel.rb against
#     carray_kernels.stamp and triggers need_extconf, so extconf reruns,
#     mkkernel regenerates, the stamp is touched and make compiles.
#     Transparent to the caller.
#   - bare `cd ext && make`: changes to mkkernel.rb are not picked up.  That
#     is advanced usage -- run extconf explicitly after touching mkkernel.rb.

carray_call_cfunc.c carray_call_cfunc.h: mk_call_cfunc.rb
	${RUBY} mk_call_cfunc.rb

yard:
	sh utils/create_rdoc.sh

clean-generated:
	@rm -f carray_config.h lib/carray/config.rb
	@rm -f carray_cast_func.c carray_kernels.c carray_kernels_*.c carray_kernels.stamp
	@rm -f ${GEMFILE}
	@rm -rf pkg
	@rm -f rdoc_ext.rb
	@rm -rf doc
	@rm -rf conftest.dSYM ext/*/conftest.dSYM

distclean:  clean-generated 
HERE_END

mk.close



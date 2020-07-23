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

major = RbConfig::CONFIG['MAJOR'].to_i
minor = RbConfig::CONFIG['MINOR'].to_i
teeny = RbConfig::CONFIG['TEENY'].to_i
RUBY_VERSION_CODE = major * 100 + minor * 10 + teeny
$defs.push "-DRUBY_VERSION_CODE=#{RUBY_VERSION_CODE}"

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

$CFLAGS += " -Wall -O2"
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

if RUBY_VERSION_CODE < 191
  if have_type("long long", header)
    check_sizeof("long long")
  end
  if have_type("float", header)
    check_sizeof("float", header)
  end
  if have_type("double", header)
    check_sizeof("double", header)
  end
  if have_type("long double", header)
    check_sizeof("long double")
  end
  if have_header("complex.h")
    complex_h = "complex.h"
    if have_type("float complex",  complex_h)
      check_sizeof("float complex", complex_h)
    end
    if have_type("double complex", complex_h)
      check_sizeof("double complex", complex_h)
    end
  else
    complex_h = nil
  end
else
	have_type("long long", header)
	have_type("float", header)
	have_type("double", header)
  if have_type("long double", header)
    check_sizeof("long double")
  end
  if have_header("complex.h")
    complex_h = "complex.h"
    have_type("float complex",  complex_h)
    have_type("double complex", complex_h)
  else
    complex_h = nil
  end
end

# --- check tgmath.h

have_header("tgmath.h")

# --- check mergesort routine

have_func("mergesort", "stdlib.h")

# --- setup install files

$INSTALLFILES = []
$INSTALLFILES << ['carray.h', '$(archdir)']
$INSTALLFILES << ['carray_config.h', '$(archdir)']

# --- cygwin/mingw
#
# Installing the static link library "libcarray.a".
# This technique is based on extconf.rb in Ruby/NArray distribution.
#

if /cygwin|mingw/ =~ RUBY_PLATFORM
  sitearchdir = Config::CONFIG["sitearchdir"]
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

# --- create carray_math.c, carray_stat_proc.c

if ( not File.exist?("carray_cast_func.c") ) or
    File.stat("carray_cast_func.rb").mtime > File.stat("carray_cast_func.c").mtime
  system("ruby carray_cast_func.rb > carray_cast_func.c")
end

if ( not File.exist?("carray_math.c") ) or
    File.stat("carray_math.rb").mtime > File.stat("carray_math.c").mtime
  system("ruby carray_math.rb")
end

if ( not File.exist?("carray_stat_proc.c") ) or
    File.stat("carray_stat_proc.rb").mtime > File.stat("carray_stat_proc.c").mtime
  system("ruby carray_stat_proc.rb > carray_stat_proc.c")
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

carray_stat_proc.c: carray_stat_proc.rb
	${RUBY} carray_stat_proc.rb > carray_stat_proc.c

carray_math.c: carray_math.rb
	${RUBY} carray_math.rb

yard:
	sh utils/create_rdoc.sh

clean-generated:
	@rm -f carray_config.h lib/carray/config.rb
	@rm -f carray_cast_func.c carray_math.c carray_stat_proc.c
	@rm -f ${GEMFILE}
	@rm -rf pkg
	@rm -f rdoc_ext.rb
	@rm -rf doc
	@rm -rf conftest.dSYM ext/*/conftest.dSYM

distclean:  clean-generated 
HERE_END

mk.close



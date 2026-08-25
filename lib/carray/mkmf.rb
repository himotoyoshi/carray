require 'mkmf'

# Locates an installed Ruby/CArray and wires its header (and, on Windows,
# its import library) into the extension being configured.  Call this at the
# top of a companion gem's `extconf.rb`.
#
# @return [Boolean] whether every required piece was found.
def have_carray 
  begin
    require 'carray'
  rescue LoadError
    abort "Ruby/CArray is not installed"
  end
  $LOAD_PATH.each do |path|
    if File.exist? File.join(path, 'carray.h')
      dir_config("carray", path, path)
      break
    end
  end
  status = true
  status &= have_header("carray.h")
  if /cygwin|mingw/ =~ RUBY_PLATFORM
    status &= have_library("carray")
  end
  status
end

# @!visibility private
def possible_prefix (*postfixes)
  dirs = [
    ENV["CONDA_PREFIX"],           ### active conda / mamba env
    ENV["HOMEBREW_PREFIX"],        ### Homebrew (non-standard install path)
    File.expand_path("~/usr"),     ### user's home / usr
    File.expand_path("~/local"),   ### user's home / local
    File.expand_path("~/.local"),  ### user's home / .local (XDG, pip --user)
    File.expand_path("~"),         ### user's home
    "/opt/local",                  ### MacPorts
    "/opt/homebrew",               ### Homebrew (Apple Silicon)
    "/opt",                        ### UNIX
    "/sw/local",                   ### Mac Fink
    "/sw/",                        ### Mac Fink
    "/usr/X11R6",                  ### UNIX X11
    "/usr/local",                  ### UNIX
    "/usr",                        ### UNIX
    "/"                            ### UNIX
  ].compact
  if postfixes
    dirs = postfixes.inject(dirs) { |list, postfix|
      list + dirs.map{|d| File.join(d, postfix) }
    }
  end 
  return dirs.select{|d| File.directory?(d)}
end

# @!visibility private
POSSIBLE_PREFIX = possible_prefix()

# @!visibility private
def possible_libs (*postfixes)
  dirs = possible_prefix().map{|prefix| File.join(prefix, "lib") }
  if postfixes
    dirs = postfixes.inject(dirs) { |list, postfix|
      list + dirs.map{|d| File.join(d, postfix) }
    }
  end 
  return dirs.select{|d| File.directory?(d)}
end

# @!visibility private
def possible_includes (*postfixes)
  dirs = possible_prefix().map{|prefix| File.join(prefix, "include") }
  if postfixes
    dirs = postfixes.inject(dirs) { |list, postfix|
      list + dirs.map{|d| File.join(d, postfix) }
    }
  end
  return dirs.select{|d| File.directory?(d)}
end

# Configure include/library search for a dependency, preferring its own
# build description over brute-force prefix probing.
#
# If the dependency ships a pkg-config file (`<pkg>.pc`), use it to obtain
# cflags / libs and stop.  Otherwise fall back to scanning possible_includes
# / possible_libs (the only option for hand-rolled scientific libraries
# that do not provide a `.pc` file, e.g. nn / ngmath / FITPACK).
#
#   carray_dir_config("gsl")           # gsl.pc -> done
#   carray_dir_config("nn")            # no .pc -> possible_* probe
#   carray_dir_config("foo", "libfoo") # search foo.pc / libfoo.pc as "libfoo"
#
def carray_dir_config (name, pkg = name)
  return true if pkg_config(pkg)
  dir_config(name, possible_includes, possible_libs)
  true
end

# --- pluggable Fortran backend registry
#
# CArray no longer tries to enumerate every Fortran compiler.  Only
# gfortran ships out of the box.  A companion gem (or a user's extconf)
# that needs another compiler registers a backend *before* calling
# check_fortran:
#
#   register_fortran_backend(/ifx|ifort/) do |fc|
#     libdir = ...                              # locate the runtime
#     dir_config("ifcore", possible_includes, [libdir] + possible_libs)
#     have_library("ifcore")
#   end
#   check_fortran("--with-fortran=ifx")
#
# A backend receives the compiler command and is responsible only for
# linking that compiler's runtime library (dir_config + have_library).
#
# @!visibility private
FORTRAN_BACKENDS = {}

# Registers a Fortran runtime backend for {check_fortran} to pick up.  Only
# gfortran ships out of the box; a companion gem that needs another compiler
# registers its own before calling {check_fortran}.  The block receives the
# compiler command and is responsible only for linking that compiler's
# runtime library (`dir_config` + `have_library`).
#
# @param pattern [Regexp] matched against the configured compiler command.
# @yieldparam fc [String] the compiler command.
# @return [void]
def register_fortran_backend (pattern, &block)
  FORTRAN_BACKENDS[pattern] = block
end

# gfortran: the one compiler CArray supports out of the box.
register_fortran_backend(/gfortran/) do |fc|
  libdir = File.dirname(`#{fc} --print-file-name=libgfortran.a`.strip)
  dir_config("gfortran", possible_includes, [libdir] + possible_libs)
  have_library("gfortran")
end

# Configures the extension to compile Fortran sources, selecting the compiler
# from `--with-fortran` (default `gfortran`) and its flags from
# `--with-fflags`.  The matching backend registered by
# {register_fortran_backend} links that compiler's runtime; an unmatched
# compiler warns and leaves the runtime to `LIBS` / `--with-fflags`.
#
# @return [void]
def check_fortran

  SRC_EXT << "f" << "f90" << "f95"

  fc     = with_config("fortran", "gfortran")
  fflags = with_config("fflags", "-O2 -g -fPIC")

  _pattern, backend = FORTRAN_BACKENDS.find { |pat, _| pat =~ fc }
  if backend
    backend.call(fc)
  else
    warn "carray/mkmf: no backend for fortran '#{fc}'; " \
         "register one with register_fortran_backend or pass the " \
         "runtime via LIBS / --with-fflags"
  end

  at_exit do
    if File.file?("Makefile")
      makefile = File.read("Makefile")
      unless makefile =~ /^FC=/
        makefile.sub!(/^COPY =.*$/,
                      '\0' + "\n\n" +
                      "FC=#{fc}\n" +
                      "FFLAGS=#{fflags}\n")
      end
      File.write("Makefile", makefile)
    end
  end

  return fc
end

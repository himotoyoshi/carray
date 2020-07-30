# ----------------------------------------------------------------------------
#
#  carray/mkmf.rb
#
#  This file is part of Ruby/CArray extension library.
#
#  Copyright (C) 2005-2020 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------

require 'mkmf'

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
=begin  
  dir_config("carray", $sitearchdir, $sitearchdir)
  if defined? Gem
    if Gem::VERSION >= "1.7.0"
      begin
        Gem::Specification.find_all_by_name("carray").each do |spec|
          dir = spec.full_gem_path
          dir_config("carray", dir, dir)      
        end
      rescue Gem::LoadError
      end
    else
      Gem.all_load_paths.grep(/narray/).each do |dir|
        dir_config("carray", dir, dir)      
      end
    end
  end
=end
  status = true
  status &= have_header("carray.h")
  if /cygwin|mingw/ =~ RUBY_PLATFORM
    status &= have_library("carray")
  end
  status
end

def check_fortran

  SRC_EXT << "f" << "f90" << "f95"

  fortran = with_config("fortran", "gfortran")
  fflags  = with_config("fflags", "")

  case fortran
  when /\Ag77/
    libdir = File.dirname(`#{fortran} --print-file-name=libg2c.a`)
    dir_config("g2c", possible_includes, [libdir]+possible_libs)
    have_library("g2c")
    fc = fortran
    fflags << " -O2 -g "
  when /\Agfortran/
    libdir = File.dirname(`#{fortran} --print-file-name=libgfortran.a`)
    dir_config("gfortran", possible_includes, [libdir]+possible_libs)
    have_library("gfortran")
    fc = fortran
    fflags << " -O2 -g -fPIC "
  when /\Aintel/, /\Aifort/, /\Aifc/
    libdir = File.join(File.dirname(File.dirname(`which ifort`)), "lib")
    dir_config("ifcore", possible_includes, [libdir]+possible_libs)
    have_library("ifcore")
    have_library("ifport")
    have_library("imf")
    have_library("irc")
    have_library("svml")
    have_library("unwind")
    fc = "ifort"
    fflags << " -O2 -fPIC "
  when /\Afujitsu/, /\Afrt/
    libdir = File.join(File.dirname(File.dirname(`which frt`)), "lib")
    dir_config("fj9f6", nil, libdir)
    $LIBS = " -lfj9i6 -lfj9f6"
    fc = "frt"
    fflags = " -O -fw "
  else
    puts "unknown fortran option <#{fortran}>"
    exit(1)
  end
  at_exit {
    if File.file?("Makefile")
      makefile = File.read("Makefile")
      unless makefile =~ /^FC=/
        makefile.sub!(/^COPY =.*$/, 
                      '\0' + "\n\n" +
                      "FC=#{fc}\n" +
                      "FFLAGS=#{fflags}\n")
      end
      open("Makefile", "w") { |io| io.write(makefile) }
    end
  }

  return "--with-fortran='#{fortran}' --with-fflags='#{fflags}'"

end

def possible_prefix (*postfixes)
  dirs = [
    File.expand_path("~/usr"),   ### user's home / usr
    File.expand_path("~/local"), ### user's home / local
    File.expand_path("~"),       ### user's home
    "/opt/local",                ### MacPorts
    "/opt",                      ### UNIX 
    "/sw/local",                 ### Mac Fink
    "/sw/",                      ### Mac Fink
    "/usr/X11R6",                ### UNIX X11
    "/usr/local",                ### UNIX
    "/usr",                      ### UNIX
    "/"                          ### UNIX
  ]
  if postfixes
    dirs = postfixes.inject(dirs) { |list, postfix|
      list + dirs.map{|d| File.join(d, postfix) }
    }
  end 
  return dirs.select{|d| File.directory?(d)}
end

POSSIBLE_PREFIX = possible_prefix()

def possible_libs (*postfixes)
  dirs = possible_prefix().map{|prefix| File.join(prefix, "lib") }
  if postfixes
    dirs = postfixes.inject(dirs) { |list, postfix|
      list + dirs.map{|d| File.join(d, postfix) }
    }
  end 
  return dirs.select{|d| File.directory?(d)}
end

def possible_includes (*postfixes)
  dirs = possible_prefix().map{|prefix| File.join(prefix, "include") }
  if postfixes
    dirs = postfixes.inject(dirs) { |list, postfix|
      list + dirs.map{|d| File.join(d, postfix) }
    }
  end 
  return dirs.select{|d| File.directory?(d)}
end

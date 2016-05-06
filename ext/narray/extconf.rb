require 'mkmf'
require 'rbconfig'
require_relative '../../lib/carray/mkmf'

dir_config("carray", "../..", "../..")

have_header("carray.h")

if /cygwin|mingw/ =~ RUBY_PLATFORM
  have_library("carray")
end

# --- 

dir_config("narray", $sitearchdir, $sitearchdir)

if defined? Gem
  if Gem::VERSION >= "1.7.0"
    begin
      Gem::Specification.find_all_by_name("narray").each do |spec|
        dir = spec.full_gem_path
        dir_config("narray", dir, dir)      
        dir_config("narray", File.join(dir,"src"), File.join(dir,"src"))      
      end
    rescue Gem::LoadError
    end
  else
    Gem.all_load_paths.grep(/narray/).each do |dir|
      dir_config("narray", dir, dir)      
      dir_config("narray", File.join(dir,"src"), File.join(dir,"src"))      
    end
  end
end

if have_header("narray.h")
  if /cygwin|mingw/ =~ RUBY_PLATFORM
    unless have_library("narray")
      open("Makefile", "w") { |io|
        io << "all:" << "\n"
        io << "install:" << "\n"        
        io << "clean:" << "\n"
        io << "distclean:" << "\n"     
        io << "\trm -rf mkmf.log Makefile" << "\n"     
      }
    end
  end
  create_makefile("carray/carray_narray")
else
  open("Makefile", "w") { |io|
    io << "all:" << "\n"
    io << "install:" << "\n"        
    io << "clean:" << "\n"
    io << "distclean:" << "\n"     
    io << "\trm -rf mkmf.log Makefile" << "\n"     
  }
end


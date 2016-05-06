require 'mkmf'

dir_config("carray", "../..", "../..")

have_header("carray.h")

if /cygwin|mingw/ =~ RUBY_PLATFORM
  have_library("carray")
end

create_makefile("carray/carray_imagemap")



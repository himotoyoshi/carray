require "mkmf"

dir_config("carray", "../..", "../..")

have_header("carray.h")

if /cygwin|mingw/ =~ RUBY_PLATFORM
  have_library("carray")
end

have_header("tgmath.h")

have_func("atan2",  "math.h")
have_func("hypot",  "math.h")
have_func("lgamma", "math.h")
have_func("expm1",  "math.h")

create_makefile("carray/carray_mathfunc")

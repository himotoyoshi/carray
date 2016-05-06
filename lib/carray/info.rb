# ----------------------------------------------------------------------------
#
#  carray/info.rb
#
#  This file is part of Ruby/CArray extension library.
#  You can redistribute it and/or modify it under the terms of
#  the Ruby Licence.
#
#  Copyright (C) 2005 Hiroki Motoyoshi
#
# ----------------------------------------------------------------------------


require "carray"

printf "\n"
printf "CArray Environment Information\n"
printf "==============================\n"
printf "\n"
printf "# version\n"
printf "    CArray::VERSION      -> %s\n", CArray::VERSION
printf "    CArray::VERSION_DATE -> %s\n", CArray::VERSION_DATE
printf "\n"
printf "# supports\n"
printf "    CArray::HAVE_COMPLEX -> %s\n", CArray::HAVE_COMPLEX
printf "    CArray::HAVE_NARRAY  -> %s\n", CArray::HAVE_NARRAY
printf "\n"
printf "# limitations\n"
printf "    CA_RANK_MAX  -> %2i\n", CA_RANK_MAX
printf "\n"
printf "# data types\n"
[
  "CA_FIXLEN",
  "CA_INT8",
  "CA_UINT8",
  "CA_INT16",
  "CA_UINT16",
  "CA_INT32",
  "CA_UINT32",
  "CA_INT64",
  "CA_UINT64",
  "CA_FLOAT32",
  "CA_FLOAT64",
  "CA_FLOAT128",
  "CA_CMPLX64",
  "CA_CMPLX128",
  "CA_CMPLX256",
  "CA_OBJECT",
  "CA_BYTE",
  "CA_SHORT",
  "CA_INT",
  "CA_FLOAT",
  "CA_DOUBLE",
  "CA_COMPLEX",
  "CA_DCOMPLEX",
].each do |name|
  data_type = eval(name)
  if CArray.data_type?(data_type)
#    printf("    %-12s -> %2i    [bytes -> %2i]\n",
#           name, data_type, CArray.sizeof(data_type))
  else
    printf("    %-12s -> not available\n", name)
  end
end

printf "\n"
printf "# default CArray classes\n"
carrays = []
cavirtuals = []
ObjectSpace.each_object(Class) do |c|
  if c <= CAVirtual
    cavirtuals.push c
  elsif c <= CArray
    carrays.push c
  end
end
printf "    entity  -> %2i [%s]\n", carrays.size, carrays.join(", ")
printf "    virtual -> %2i\n", cavirtuals.size

printf "\n"
printf "# default CArray methods\n"
o = Object.new
a = CArray.int(3)
list = a.methods - o.methods
printf "    methods  -> %2i\n", list.size

def which (cmd)
  return ENV["PATH"].split(":").detect do |dir|
    filename = File.join(dir, cmd)
    File.executable?(filename)
  end
end

printf "\n"
printf "# helper commands\n"

[
  ["gnuplot", ["carray/graphics/gnuplot.rb"]],
  ["convert", ["carray/io/imagemagick.rb"]],
  ["display", ["carray/io/imagemagick.rb"]],
  ["identify", ["carray/io/imagemagick.rb"]],
  ["stream", ["carray/io/imagemagick.rb"]],
].each do |cmd, libs|
  path = which(cmd)
  if path
    printf("    %s -> installed, required by %s\n", cmd, libs.join(","))
  else
    printf("    %s -> not installed, required by %s\n", cmd, libs.join(","))
  end
end

printf "\n"

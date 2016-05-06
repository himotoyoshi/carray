require "fortio"

a = CArray.float(3).seq!

fortran_sequential_open("test.dat", "w") { |io|
  io.write(a)
}

fortran_sequential_open("test.dat") { |io|
  p io.read.unpack("e3")
}

File.unlink("test.dat")
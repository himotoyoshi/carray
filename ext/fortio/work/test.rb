require "carray"

text =<<END
  1  2  3  4
  5  6  7  8
END

ca = CArray.from_fortran_format("2I3,2F3.0/2F3.0,2I3", text)

ca.to_fortran_format("2I3,1P,2E10.2E3", STDOUT)

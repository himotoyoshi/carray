require "fortio"

fortran_format_write(STDOUT, "(TR12,A1)", "a")
fortran_format_write(STDOUT, "(TR12,A1,TL5,A1,TL3,A1)", "a", "b", "c")
fortran_format_write(STDOUT, "(TR12,A1,T5,A1,T3,A1)", "a", "b", "c")

p FortranFormat.new("(A12)")

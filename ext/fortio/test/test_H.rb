require "fortio"

p FortranFormat.new("((5(5Hhello)$))")

puts fortran_format("(2(5(5Hhello))$)")

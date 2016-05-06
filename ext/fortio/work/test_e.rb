require "fortio"

p f = FortranFormat("4(2P,3E6.2E4,2I2.1)$")
p f.count_args
p fortran_format("2P,E10.2E4,$", 0.000012345)
p f = FortranFormat("2(E10.2E4,',')")
p fortran_format("2(E10.2E4,',')", 0.000012345, 2.0)
p f = FortranFormat('2(-2PG15.5 4X2(I2)/)')
puts fortran_format(f, 3.1415926,2,4, 2.71828,3,5)

p f = FortranFormat('3P,4(G15.5/)')
p f.count_args
puts fortran_format(f, 0.1, 0.11, 10**5-1, 10**5)

p f = FortranFormat('A10,"""\'|\'"""')
p f.count_args
puts fortran_format(f, "hello")

puts fortran_format_read("12345", "F5.2")
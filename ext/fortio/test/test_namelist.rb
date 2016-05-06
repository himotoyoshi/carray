require "fortio"
require "pp"

text =<<END
aaaa bbbb cccc
dddd eeee ffff
&name
 c=30.d0,
 a=10.d0,
 b=20.d0,
 d(1:3) = 1,2,3
 &end
&foo
 c=10.d+32,
 a=50.d0,
 b=90.d0,
 d(1:5) = 3*4,,3
 e="hello""world!"
 &end
END

pp nml = fortran_namelist_read(text, "name", {:d=>CArray.int(3)})
pp nml = fortran_namelist_read(text, "foo", {:d=>CArray.int(5)})

puts fortran_namelist("bar", nml)
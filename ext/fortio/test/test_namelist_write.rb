require "fortio"

a = {
  :array => [1,2,3],
  :x => 1,
  :y => 2.2
}

fortran_namelist_write(STDOUT, "a", a)
fortran_namelist_write(STDOUT, "a", a)

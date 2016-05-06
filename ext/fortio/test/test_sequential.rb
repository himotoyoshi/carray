require "fortio"

fs = FortranSequential.open("test.dat", "w", :endian=>"big")
rec = fs.record
rec.write("d4l", [1.2, 2008, 6, 21, 9])
fs.close

fs = FortranSequential.open("test.dat", "r", :endian=>"big")
rec = fs.record
p rec.read("d4l")
fs.close

File.unlink("test.dat")

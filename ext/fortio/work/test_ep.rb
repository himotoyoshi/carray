require "fortio"

fmt200 = FortranFormat.new("(3pe13.6,-2p2e13.6)")

p fortran_format_write("", fmt200, *[0.000123456]*3)

p text = fortran_format_write("", "3pf10.5", 3)
p fortran_format_read(text, "3pf10.5")

p fortran_format_write("", "g13.5", 893)
require 'fortio'

include Math

#F77 = "ifort"
F77 = "gfortran"
#F77 = "g95"
#F77 = "g77"

def f77_compile_and_run (source)
  output = nil
  begin
    open("test.f", "w") { |io|
      io.write(source)
    }
    system("#{F77} test.f")
    output = `./a.out`.chomp
  ensure
    File.unlink("test.f")
    File.unlink("a.out")
  end
end

[
 ["F12.3",    10.0,        nil],
 ["2F12.3",   [10.0,11.0], nil],
 ["E12.2",    10.0,        nil],
 ["2E12.2",   [10.0,11.0], nil],
 ["2PE12.2",  10.0,        nil],
 ["2P2E12.2", [10.0,11.0], nil],
 ["2G12.2",   [10.0,11.0], nil],
 ["2PG12.2",  10.0,        nil],
 ["2PG12.2E3",10.0,        nil],
 ["2PG12.2",  1234567890.0,        nil],
 ["2PG12.2E3",1234567890.0,        nil],
 # ---
 ["F15.8",    PI, "#{PI}D0"],
 ["E15.8",    PI, "#{PI}D0"],
 ["2PE15.8",  PI, "#{PI}D0"],
 # ---
 ["F10.8",    PI, "#{PI}D0"],
 ["E10.8",    PI, "#{PI}D0"],
 ["2PE10.8",  PI, "#{PI}D0"],
 # ---
 ["I4.3",     123456,     nil],
 ["I6.5",     123,        nil],
 ["I6.5",     123,        nil],
 ["I7.6",     123456,     nil],
 ["I6",       123456,     nil],
 # ---
 ["SPI6",      123456,    nil],
 ["SPI7",      123456,    nil],
 ["SPF12.4",   123456.0,  nil],
 ["SPE12.4E3", 123456.0,  nil],
 ["SPG12.4E3", 123456.0,  nil],
 ["SPG12.4E3", 123.0,     nil],
 ["TR2SPSG12.4E3", 123.0, nil],
 # ---
 ["L1",        true,     ".TRUE."],
 ["L1",        false,    ".FALSE."],
 ["L2",        true,     ".TRUE."],
 ["L2",        false,    ".FALSE."],
 ["L4",        true,     ".TRUE."],
 ["L4",        false,    ".FALSE."],
 # ---
 ["A1",        "a",     "'a'"],
 ["A2",        "ab",    "'ab'"],
 ["5Hhello",   nil,  nil],
 # ---
 ["/",        "\n",     ""],
 ["2/",        "\n\n",     ""],
].each do |fmt, rval, fval|
  fort_out = f77_compile_and_run %{
      write(6, '(#{fmt})') #{[fval||rval||[]].flatten.join(',')}
      end
  }
  ruby_out = fortran_format(fmt+"$", *rval)
  puts "-------------------------------------------------------------"
  printf("format         : %s\n", fmt)
  printf("fortran input  : %s\n", [fval||rval].flatten.join(','))
  printf("ruby input     : %s\n", [rval].flatten.join(","))
  printf("fortran output : %s\n", fort_out.inspect)
  printf("ruby output    : %s\n", ruby_out.inspect)
  printf("comparison     : %s\n", fort_out == ruby_out)
end


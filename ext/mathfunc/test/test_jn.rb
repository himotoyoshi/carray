require "carray"

p x = CAMath.yn(1, CA_FLOAT(0..100))

CA.gnuplot { |g|
  g.plot2d([x], :with=>"lines")
}


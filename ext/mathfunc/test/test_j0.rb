require 'carray'

x = CArray.float(101).span(0..10)

CA.gnuplot { |g|
  g.plot2d(
           [x, x.erf],
           [x, x.erfc]
           )
  g.plot2d(
           [x, x.j0],
           [x, x.j1],
           [x, x.jn(2)],
           [x, x.jn(3)],
           [x, x.jn(4)],
           [x, x.jn(5)]
           )
  g.plot2d(
           [x, x.y0],
           [x, x.y1]
           )
}

require 'carray'

p x = CArray.object(101).span(0..1)

p CAMath.hypot(x[:*,nil], x[nil,:*])

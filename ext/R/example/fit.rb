require "carray"
require "R"

R.run

x = CArray.float(200).span(0..4r)
v = x.random(4)-2

a = 3
b = 5
c = 7
y = a*x**2 + b*x + c + v

res = R %{ 
  nls(y ~ a*x^2 + b*x + c, start=c(a=100,b=1,c=1), trace=TRUE) 
}, :x=>x, :y=>y

a1,b1,c1 = R.coef(res).to_ruby.values_at("a","b","c")

CA.gnuplot {
  plot [x,y],
       [x,a1*x**2+b1*x+c, nil, "lines"]
}


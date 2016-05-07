require "R"

R.run

iris = R.iris

CA.gnuplot {
  plot [iris.Sepal_Length, iris.Sepal_Width]
}

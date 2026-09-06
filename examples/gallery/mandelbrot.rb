# frozen_string_literal: true
#
# gallery/mandelbrot.rb
#
# The Mandelbrot set computed on a 2-D grid, all at once. Every step of
# the iteration is applied to the whole plane in a single expression;
# there is no inner loop over the pixels.

require "carray"

# ------------------------------------------------------------
# The grid of complex numbers c = cx + i * cy
# ------------------------------------------------------------
# cx has shape (1, W) and cy has shape (H, 1). Combined with Complex::I
# they broadcast to a (H, W) grid of complex numbers in one expression.
w, h     = 78, 30
max_iter = 40

cx = CArray.float64(1, w).seq(-2.1, 3.0 / (w - 1))
cy = CArray.float64(h, 1).seq(-1.2, 2.4 / (h - 1))
c  = cx + Complex::I * cy

# ------------------------------------------------------------
# The state of the iteration, one cell per pixel
# ------------------------------------------------------------
# z holds the current point of every orbit; iters records the iteration
# at which the orbit escapes the disc of radius 2. Points that never
# escape stay at max_iter.
z     = CArray.cmplx128(h, w)
iters = CArray.int32(h, w) { max_iter }

# ------------------------------------------------------------
# Iterate the whole plane in one go
# ------------------------------------------------------------
# `z.abs2 > 4.0` is the escape test — squared magnitude, no `sqrt`.
# The cells that escape for the first time have their escape iteration
# written; the recurrence z <- z^2 + c updates every point.
max_iter.times do |k|
  first_escape = ( z.abs2 > 4.0 ) & iters.eq(max_iter)
  iters[first_escape] = k
  z = z * z + c
end

# ------------------------------------------------------------
# Render as ASCII
# ------------------------------------------------------------
# The character index is computed for the whole plane in one expression
# (integer arithmetic, clipped into the palette range). Because iters
# for interior points equals max_iter, they land on the last palette
# slot naturally, without a separate branch. `.lookup(palette)` gathers
# the characters from a 1-D object table, preserving the (h, w) shape.
palette_str = " .,:;+xX%#@"
palette     = CA_OBJECT(palette_str.split(""))
idx         = ( iters * (palette_str.length - 1) / max_iter ).clip(0, palette_str.length - 1)

puts idx.lookup(palette).join(axis: 1).join("\n")

# ------------------------------------------------------------
# What escaped, and how fast
# ------------------------------------------------------------
# The count of interior points and the mean escape time of the exterior
# come out as one-liners.
inside  = iters.eq(max_iter)
outside = ~inside
puts
puts "grid:            #{h} x #{w}  (#{h * w} points)"
puts "inside the set:  #{inside.sum} points"
puts "mean escape:     #{iters[outside].mean.round(2)} iterations"

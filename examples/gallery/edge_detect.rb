# frozen_string_literal: true
#
# gallery/edge_detect.rb
#
# The Sobel edge detector, expressed as shifted views. The horizontal
# and vertical Sobel kernels are 3x3 convolutions; each one is a
# combination of six shifted copies of the image, with no per-pixel
# loop. Threshold the squared gradient magnitude (no sqrt) to pick out
# the edges.

require "carray"

# ------------------------------------------------------------
# A synthetic image with two solid rectangles
# ------------------------------------------------------------
# Two rectangles of different brightness give us corners, straight
# edges, and interior area — enough to see that the detector picks up
# outlines and leaves the flat interior alone.
h, w = 20, 60
img = CArray.float64(h, w)
img[ 5..14, 10..25 ] = 200.0
img[ 3..12, 35..50 ] = 150.0

# ------------------------------------------------------------
# The Sobel operator, as shifted views
# ------------------------------------------------------------
# The Sobel Gx kernel is
#
#     -1  0  +1
#     -2  0  +2
#     -1  0  +1
#
# which is the right column minus the left column, weighted [1, 2, 1]
# down the rows. `img.shift(dr, dc)[i, j]` reads `img[i - dr, j - dc]`,
# so shifting the image by (dr, dc) *brings the neighbour at offset
# (-dr, -dc) into position (i, j)*. That gives us the six taps.
right_col = img.shift( 1, -1) + 2 * img.shift( 0, -1) + img.shift(-1, -1)
left_col  = img.shift( 1,  1) + 2 * img.shift( 0,  1) + img.shift(-1,  1)
gx        = right_col - left_col

bottom_row = img.shift(-1, -1) + 2 * img.shift(-1,  0) + img.shift(-1,  1)
top_row    = img.shift( 1, -1) + 2 * img.shift( 1,  0) + img.shift( 1,  1)
gy         = bottom_row - top_row

# ------------------------------------------------------------
# Squared magnitude and threshold
# ------------------------------------------------------------
# `abs2` gives x*x for real inputs, so `gx.abs2 + gy.abs2` is the
# squared gradient magnitude without a `sqrt`. Comparing against a
# fraction of its own maximum picks up the strong edges and ignores
# the flat interior.
mag2  = gx.abs2 + gy.abs2
edges = ( mag2 > mag2.max * 0.25 )

# ------------------------------------------------------------
# Render
# ------------------------------------------------------------
def show(bool_ca, on: "#", off: ".")
  chars = bool_ca.then_else(CA_OBJECT(on), CA_OBJECT(off))
  puts chars.join(axis: 1).join("\n")
end

puts "original (filled interior):"
show(img > 0)
puts
puts "detected edges (outline only):"
show(edges)
puts
puts "gradient magnitude^2: min = #{mag2.min.round(1)}, " \
     "max = #{mag2.max.round(1)}"
puts "edge pixels: #{edges.sum} of #{h * w}"

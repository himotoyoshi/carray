# frozen_string_literal: true
#
# gallery/image_threshold.rb
#
# Basic image processing on a 2-D array. Threshold an 8-bit image into
# black and white in a single expression, then dilate the result by
# combining shifted views.

require "carray"

#  Print a boolean array as ASCII: true -> on, false -> off.
#  then_else broadcasts the two scalar CA_OBJECTs to the full shape,
#  giving an object array of characters. `.join(axis: 1)` collapses
#  each row into a single string; the outer `.join("\n")` joins those
#  row strings into one printable block.
def show(bool_ca, on: "#", off: ".")
  chars = bool_ca.then_else(CA_OBJECT(on), CA_OBJECT(off))
  puts chars.join(axis: 1).join("\n")
end

# ------------------------------------------------------------
# A synthetic image
# ------------------------------------------------------------
# A 16-by-40 uint8 image made of a smooth Gaussian bump and a small
# bright spot. Two seq arrays of shapes (h, 1) and (1, w) supply the
# row and column coordinates; the whole picture is then a single
# elementwise expression over the (h, w) grid.
h, w   = 16, 40
cy, cx = h / 2.0, w / 2.0
yy     = CArray.float64(h, 1).seq
xx     = CArray.float64(1, w).seq

d2   = ((yy - cy) / 6.0) ** 2 + ((xx - cx) / 15.0) ** 2
bump = (255 * (-d2).exp).int32
spot = ( (yy - 3).abs + (xx - 32).abs < 2 ).int32 * 255
img  = (bump + spot).clip(0, 255).uint8

#  Render as a five-level grayscale via a lookup table.
level = CA_OBJECT(" .:+#".split(""))
puts "original as a five-level grayscale ( .:+# ):"
puts (img.int32 * 5 / 256).lookup(level).join(axis: 1).join("\n")

# ------------------------------------------------------------
# Threshold at 128
# ------------------------------------------------------------
# A comparison returns a boolean array of the same shape. That is the
# thresholded image, in one expression. There is no need to allocate an
# output buffer and fill it in two passes.
foreground = ( img >= 128 )

puts "\nthresholded at 128:"
show(foreground)

# ------------------------------------------------------------
# Dilation by one pixel
# ------------------------------------------------------------
# A pixel becomes foreground if any of its four neighbours (or itself)
# is already foreground. shift returns a view of the same shape as the
# input, filled with false at the edge that would come from outside;
# combining five such views with elementwise OR is the whole dilation.
dilated = foreground |
          foreground.shift( 1,  0) |
          foreground.shift(-1,  0) |
          foreground.shift( 0,  1) |
          foreground.shift( 0, -1)

puts "\ndilated by one pixel:"
show(dilated)

# ------------------------------------------------------------
# Convert the foreground to an 8-bit image
# ------------------------------------------------------------
# When the boolean has to leave CArray as an image, multiplying by 255
# and casting to uint8 gives the familiar 0 / 255 byte image in one
# expression.
binary = foreground.uint8 * 255
puts "\nbyte-image summary:"
puts "  data_type: #{binary.data_type}"
puts "  min / max: #{binary.min} / #{binary.max}"

# ------------------------------------------------------------
# Count the foreground area
# ------------------------------------------------------------
# A boolean array sums as 0 and 1, so counting foreground pixels is
# just sum.
puts "\nforeground pixel counts:"
puts "  before dilation: #{foreground.sum}"
puts "  after dilation:  #{dilated.sum}"

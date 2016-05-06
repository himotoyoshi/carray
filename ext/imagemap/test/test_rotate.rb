require "carray"

img = ImageMap.new(:int16, [300, 300]) {0}
img.set_xrange 0...300
img.set_yrange 0...300

data = CArray.int16(16,16).seq!

x = CArray.float(16).seq![16,:%]
y = CArray.float(16).seq!.reverse![:%,16]

img.warp(data, x, y, :grid=>"area0", :gradation=>false) {|gx,gy,ix,iy|
  ix[] = 8*(gy+gx) + 24
  iy[] = 8*(gy-gx) + 150
}

img.as_uint8.display_by_magick

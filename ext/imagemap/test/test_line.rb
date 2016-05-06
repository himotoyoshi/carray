require 'carray'
require 'carray/image_map'

p img = ImageMap.new(CA_INT8, [200,200]) {0}
p img.class

gx = CArray.float(2,2) { [[10,30],
                          [10,30]] }
gy = CArray.float(2,2) { [[10,10],
                          [80,50]] }

img.fill_rectangle(gy, gx, 255)

img.display_by_magick
